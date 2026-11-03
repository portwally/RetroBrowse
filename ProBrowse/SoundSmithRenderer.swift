//
//  SoundSmithRenderer.swift
//  ProBrowse
//
//  Renders SoundSmith songs ($D5/$0007) with their wave bank to stereo PCM by
//  emulating the Ensoniq 5503 DOC sound chip.
//
//  Sources:
//  - Apple II File Type Note $D5/$0007 (song layout)
//  - Sean Kasun's SoundSmith player, https://github.com/mrkite/soundsmith
//    (wave bank layout, note frequency table, DOC emulation).
//    Copyright 2017 Sean Kasun, BSD 2-Clause License:
//      Redistribution and use in source and binary forms, with or without modification, are
//      permitted provided that the following conditions are met: 1. Redistributions of source
//      code must retain the above copyright notice, this list of conditions and the following
//      disclaimer. 2. Redistributions in binary form must reproduce the above copyright notice,
//      this list of conditions and the following disclaimer in the documentation and/or other
//      materials provided with the distribution. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT
//      HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
//

import Foundation

nonisolated enum SoundSmithRenderer {

    /// The DOC runs all 32 oscillators at 894886 Hz / 34
    static let docRate = 26320.0
    static let maxSeconds = 600.0

    /// True when `data` has the shape of a SoundSmith wave bank: an instrument count,
    /// 64K of DOC RAM and the instrument records after it
    static func isWavebank(_ data: Data) -> Bool {
        guard data.count >= 0x10022 else { return false }
        let count = Int(data[data.startIndex])
        return (1...15).contains(count) && data[data.startIndex + 1] == 0
            && data.count >= 0x10022 + count * 0x5C && data.count <= 0x10022 + 0x1000
    }

    /// Picks the wave bank for a song from the files in its folder. Programs named them
    /// many ways (SONG.W, SONG.D, SONG.WBK, SONG.WAV, WAVE...), so any wave bank qualifies
    /// and the one whose name shares the longest start with the song's wins.
    static func findWavebank(forSong name: String, in companions: [String: Data]) -> (name: String, data: Data)? {
        let song = name.uppercased()
        let base = song.split(separator: ".").first.map(String.init) ?? song
        func score(_ candidate: String) -> Int {
            if candidate.hasPrefix(song + ".") { return 1000 }
            let common = zip(candidate, song).prefix { $0 == $1 }.count
            return candidate.hasPrefix(base) ? 500 + common : common
        }
        return companions.filter { isWavebank($0.value) }
            .max { (score($0.key), $1.key) < (score($1.key), $0.key) }
            .map { ($0.key, $0.value) }
    }

    struct Song {
        var tempo: Int
        var volumes: [Int]        // 15 instruments
        var orders: [Int]         // byte offsets into the note blocks
        var notes: [UInt8]
        var effects1: [UInt8]
        var effects2: [UInt8]
        var stereo: [Bool]        // true = right channel, per voice
        var instrumentNames: [String]
    }

    struct Wavebank {
        var ram: [Float]          // 64K of DOC RAM, -1...1 ($00 reads as -1)
        /// Per instrument: oscillator A's wave list, then oscillator B's. Each entry is 6 bytes
        /// (top key, DOC page, size, mode, pitch) and each list ends with top key $7F.
        var instruments: [[UInt8]]
        var compact: [Int]
    }

    // MARK: - Parsing

    static func parseSong(_ data: Data) -> Song? {
        let b = [UInt8](data)
        guard b.count > 0x258 else { return nil }
        func r16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        let blockLength = r16(6)
        let tempo = r16(8)
        guard blockLength > 0, 0x258 + blockLength * 3 <= b.count else { return nil }
        let volumes = (0..<15).map { r16(0x2C + $0 * 0x1E) }
        let songLength = Int(b[0x1D6])
        let orders = (0..<songLength).map { Int(b[0x1D8 + $0]) * 64 * 14 }
            .filter { $0 + 64 * 14 <= blockLength }
        let notes = Array(b[0x258..<0x258 + blockLength])
        let effects1 = Array(b[0x258 + blockLength..<0x258 + blockLength * 2])
        let effects2 = Array(b[0x258 + blockLength * 2..<0x258 + blockLength * 3])
        let stereoAt = 0x258 + blockLength * 3
        let stereo = (0..<16).map { r16(stereoAt + $0 * 2) != 0 }
        guard !orders.isEmpty else { return nil }
        let names = (0..<15).map { i -> String in
            let o = 0x14 + i * 0x1E
            let length = min(21, Int(b[o]))
            return String(decoding: b[o + 1..<o + 1 + length].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        }
        return Song(tempo: max(1, tempo), volumes: volumes, orders: orders, notes: notes,
                    effects1: effects1, effects2: effects2, stereo: stereo, instrumentNames: names)
    }

    static func parseWavebank(_ data: Data) -> Wavebank? {
        let b = [UInt8](data)
        guard b.count >= 0x10022 else { return nil }
        let count = Int(b[0])
        guard count > 0, count <= 15, 0x10022 + count * 0x5C <= b.count else { return nil }
        let ram = (0..<0x10000).map { (Float(b[2 + $0]) - 128) / 128 }
        let instruments = (0..<count).map { Array(b[0x10022 + $0 * 0x5C..<0x10022 + $0 * 0x5C + 12]) }
        // Pitch shift per instrument; files often end before the 16th entry, which is never used
        let compactAt = 0x10022 + count * 0x5C + 0x3C
        let compact = (0..<16).map { i -> Int in
            let o = compactAt + i * 2
            return o + 1 < b.count ? min(15, Int(b[o]) | Int(b[o + 1]) << 8) : 0
        }
        return Wavebank(ram: ram, instruments: instruments, compact: compact)
    }

    /// Builds a wave bank from ASIF instrument files, the way SoundSmith 1.0 songs keep their
    /// instruments: each named in the song header and saved next to it. Each instrument's waves
    /// are copied into DOC RAM at an address aligned to its largest wave table and the wave list
    /// addresses moved to match. Returns the bank and the names of instruments not found.
    static func buildWavebank(for song: Song, from files: [String: Data]) -> (bank: Wavebank, missing: [String])? {
        struct Loaded { let index: Int; let lists: [UInt8]; let wave: [UInt8]; let align: Int }
        var loaded: [Loaded] = []
        var missing: [String] = []
        for (index, name) in song.instrumentNames.enumerated() where !name.isEmpty {
            guard let file = files[name.uppercased()], let asif = parseASIF(file) else {
                missing.append(name)
                continue
            }
            // A table of size code n covers 256 << n bytes and must start on that boundary
            let entries = stride(from: 0, to: asif.lists.count, by: 6).map { asif.lists[$0 + 2] }
            let align = entries.map { 0x100 << Int(($0 >> 3) & 7) }.max() ?? 0x100
            loaded.append(Loaded(index: index, lists: asif.lists, wave: asif.wave, align: align))
        }
        guard !loaded.isEmpty else { return nil }

        var ram = [UInt8](repeating: 0, count: 0x10000)
        var used = [Bool](repeating: false, count: 0x100)   // per page
        var instruments = [[UInt8]](repeating: [], count: 15)
        for item in loaded.sorted(by: { $0.align > $1.align }) {
            let pages = max(1, (item.wave.count + 0xFF) / 0x100)
            let step = item.align / 0x100
            guard let base = stride(from: 0, through: 0x100 - pages, by: step).first(where: { start in
                !used[start..<start + pages].contains(true)
            }) else {
                missing.append(song.instrumentNames[item.index])   // DOC RAM is full
                continue
            }
            for p in base..<base + pages { used[p] = true }
            ram.replaceSubrange(base * 0x100..<base * 0x100 + item.wave.count, with: item.wave)
            var lists = item.lists
            for e in stride(from: 0, to: lists.count, by: 6) {
                lists[e + 1] = UInt8((Int(lists[e + 1]) + base) & 0xFF)
            }
            instruments[item.index] = lists
        }
        let bank = Wavebank(ram: ram.map { (Float($0) - 128) / 128 }, instruments: instruments,
                            compact: [Int](repeating: 0, count: 16))
        return (bank, missing)
    }

    /// The first instrument of an ASIF file: its A and B wave lists, each ending with top key $7F,
    /// and the wave data of the WAVE chunk (FTN $D8/$0002)
    static func parseASIF(_ data: Data) -> (lists: [UInt8], wave: [UInt8])? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0..<4].elementsEqual("FORM".utf8), b[8..<12].elementsEqual("ASIF".utf8) else { return nil }
        var lists: [UInt8]? = nil
        var wave: [UInt8]? = nil
        var p = 12
        while p + 8 <= b.count {
            let id = String(decoding: b[p..<p + 4], as: UTF8.self)
            // Some files (NoiseTracker GS) store a chunk size past the end of the file
            let body = p + 8
            let size = min(Int(b[p + 4]) << 24 | Int(b[p + 5]) << 16 | Int(b[p + 6]) << 8 | Int(b[p + 7]), b.count - body)
            if id == "INST" && lists == nil && size > 0 {
                // name, sample number, 8 envelope segments, 6 parameter bytes, then the wave counts
                var q = body + 1 + Int(b[body]) + 2 + 24 + 6
                guard q + 2 <= body + size else { break }
                let a = Int(b[q]), bCount = Int(b[q + 1])
                q += 2
                guard a > 0, bCount > 0, q + (a + bCount) * 6 <= body + size else { break }
                lists = Array(b[q..<q + (a + bCount) * 6])
            } else if id == "WAVE" && wave == nil && size > 0 {
                var q = body + 1 + Int(b[body])
                guard q + 4 <= body + size else { break }
                let waveSize = (Int(b[q]) | Int(b[q + 1]) << 8) + 1
                let samples = Int(b[q + 2]) | Int(b[q + 3]) << 8
                q += 4 + samples * 12
                guard q <= body + size else { break }
                wave = Array(b[q..<min(body + size, q + waveSize)])
            }
            p = body + size + (size & 1)
        }
        guard let lists, let wave else { return nil }
        return (lists, wave)
    }

    // MARK: - DOC emulation

    private struct Oscillator {
        var pointer = 0
        var frequency = 0
        var size = 0
        var resolution = 0
        var control: UInt8 = 1   // halted
        var volume: Float = 0
        var data: Float = 0
        var accumulator = 0
        var ptr = 0
        var shift = 9
        var max = 0xFF
    }

    private static let waveSizes = [0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000, 0x8000]
    private static let waveMasks = [0x1FF00, 0x1FE00, 0x1FC00, 0x1F800, 0x1F000, 0x1E000, 0x1C000, 0x18000]

    /// DOC frequency register values per semitone
    private static let frequencies: [Int] = [
        0x0000, 0x0016, 0x0017, 0x0018, 0x001a, 0x001b, 0x001d, 0x001e,
        0x0020, 0x0022, 0x0024, 0x0026, 0x0029, 0x002b, 0x002e, 0x0031,
        0x0033, 0x0036, 0x003a, 0x003d, 0x0041, 0x0045, 0x0049, 0x004d,
        0x0052, 0x0056, 0x005c, 0x0061, 0x0067, 0x006d, 0x0073, 0x007a,
        0x0081, 0x0089, 0x0091, 0x009a, 0x00a3, 0x00ad, 0x00b7, 0x00c2,
        0x00ce, 0x00d9, 0x00e6, 0x00f4, 0x0102, 0x0112, 0x0122, 0x0133,
        0x0146, 0x015a, 0x016f, 0x0184, 0x019b, 0x01b4, 0x01ce, 0x01e9,
        0x0206, 0x0225, 0x0246, 0x0269, 0x028d, 0x02b4, 0x02dd, 0x0309,
        0x0337, 0x0368, 0x039c, 0x03d3, 0x040d, 0x044a, 0x048c, 0x04d1,
        0x051a, 0x0568, 0x05ba, 0x0611, 0x066e, 0x06d0, 0x0737, 0x07a5,
        0x081a, 0x0895, 0x0918, 0x09a2, 0x0a35, 0x0ad0, 0x0b75, 0x0c23,
        0x0cdc, 0x0d9f, 0x0e6f, 0x0f4b, 0x1033, 0x112a, 0x122f, 0x1344,
        0x1469, 0x15a0, 0x16e9, 0x1846, 0x19b7, 0x1b3f, 0x1cde, 0x1e95,
        0x2066, 0x2254, 0x245e, 0x2688,
    ]

    private static func frequency(_ semitone: Int, shift: Int) -> Int {
        frequencies[max(0, min(frequencies.count - 1, semitone))] >> shift
    }

    /// The DOC plus the SoundSmith player that drives it from the timer interrupt
    private struct Machine {
        var osc = [Oscillator](repeating: Oscillator(), count: 32)
        let ram: [Float]
        let enabled = 30           // oscillators 0...30 run; 30 is the 50 Hz timer
        let song: Song
        let bank: Wavebank

        var tempo: Int
        var timer: Int
        var rowOffset = 0
        var curRow = 0
        var curPat = 0
        var stopped = false
        var curInst = [Int](repeating: 0, count: 14)
        var arpeggio = [Int](repeating: 0, count: 14)
        var tone = [Int](repeating: 0, count: 14)

        init(song: Song, bank: Wavebank) {
            self.song = song
            self.bank = bank
            ram = bank.ram
            tempo = song.tempo
            timer = song.tempo - 1
            rowOffset = song.orders[0]
            setFrequency(30, 0xFA)
            setVolume(30, 0)
            setPointer(30, 0)
            setSize(30, 0)
            setControl(30, 8)      // free run with interrupts
        }

        mutating func recalc(_ i: Int) {
            osc[i].shift = (osc[i].resolution + 9) - osc[i].size
            osc[i].ptr = osc[i].pointer & SoundSmithRenderer.waveMasks[osc[i].size]
            osc[i].max = SoundSmithRenderer.waveSizes[osc[i].size] - 1
        }
        mutating func setFrequency(_ i: Int, _ f: Int) { osc[i].frequency = f }
        mutating func setVolume(_ i: Int, _ v: Int) { osc[i].volume = Float(max(0, min(127, v))) / 127 }
        mutating func setPointer(_ i: Int, _ p: Int) { osc[i].pointer = p << 8; recalc(i) }
        mutating func setSize(_ i: Int, _ s: Int) {
            osc[i].size = (s >> 3) & 7
            osc[i].resolution = s & 7
            recalc(i)
        }
        mutating func setControl(_ i: Int, _ c: UInt8) {
            let wasHalted = osc[i].control & 1
            osc[i].control = c
            if c & 1 == 0 && wasHalted != 0 {
                if (c >> 1) & 3 == 2 {   // sync: start the pair too
                    osc[i ^ 1].control &= ~1
                    osc[i ^ 1].accumulator = 0
                }
                osc[i].accumulator = 0
            }
        }
        mutating func stop(_ i: Int) {
            osc[i].control = (osc[i].control & 0xF7) | 1
            osc[i].accumulator = 0
        }

        mutating func halted(_ i: Int, interrupted: Bool) {
            let mode = (osc[i].control >> 1) & 3
            if interrupted || mode != 0 {
                osc[i].control |= 1
            } else {
                let base = (osc[i].accumulator >> osc[i].shift) - osc[i].max
                osc[i].accumulator = max(base, 0) << osc[i].shift
            }
            if mode == 3 {   // swap: start the pair
                osc[i ^ 1].control &= ~1
                osc[i ^ 1].accumulator = 0
            }
            if osc[i].control & 8 != 0 { interrupt(i) }
        }

        /// One DOC sample period; returns the left and right mix
        mutating func tick() -> (Float, Float) {
            var left: Float = 0, right: Float = 0
            for i in 0...enabled where osc[i].control & 1 == 0 {
                let base = osc[i].accumulator >> osc[i].shift
                let offset = (base & osc[i].max) + osc[i].ptr
                let sample = ram[offset & 0xFFFF]
                osc[i].data = sample * osc[i].volume
                osc[i].accumulator += osc[i].frequency
                if sample == -1 && i != 30 {   // a $00 byte stops the oscillator (not the timer, which only counts)
                    halted(i, interrupted: true)
                } else if base >= osc[i].max {
                    halted(i, interrupted: false)
                }
                if osc[i].control & 1 == 0 {
                    if osc[i].control & 0x10 != 0 { right += osc[i].data } else { left += osc[i].data }
                }
            }
            let spread = Float(enabled - 2) / 4
            return (left / spread, right / spread)
        }

        // MARK: Player

        mutating func interrupt(_ i: Int) {
            guard i == 30 else {
                osc[i].control &= ~1
                return
            }
            timer += 1
            if timer >= tempo {
                timer = 0
                playRow()
            } else {
                applyArpeggio()
            }
        }

        mutating func playRow() {
            for voice in 0..<14 {
                guard rowOffset < song.notes.count else { stopped = true; return }
                let semitone = Int(song.notes[rowOffset])
                if semitone == 0 || semitone & 0x80 != 0 {
                    rowOffset += 1
                    if semitone == 0x80 {
                        setControl(voice * 2, 1)
                        setControl(voice * 2 + 1, 1)
                    } else if semitone == 0x81 {
                        curRow = 0x3F
                    }
                    continue
                }
                var fx = Int(song.effects1[rowOffset])
                let param = Int(song.effects2[rowOffset])
                if fx & 0xF0 != 0 { curInst[voice] = (fx >> 4) - 1 }
                let inst = curInst[voice]
                var volume = (inst < 15 ? song.volumes[inst] : 0) >> 1
                fx &= 0x0F
                if fx == 0 {
                    arpeggio[voice] = param
                    tone[voice] = semitone
                } else {
                    arpeggio[voice] = 0
                    switch fx {
                    case 3: volume = param >> 1
                    case 5: volume = min(0x7F, volume + (param >> 1))
                    case 6: volume = max(0, volume - (param >> 1))
                    case 0xF: tempo = max(1, param)
                    default: break
                    }
                }

                let a = voice * 2, b = a + 1
                stop(a)
                stop(b)
                if inst < bank.instruments.count, bank.instruments[inst].count >= 12 {
                    let table = bank.instruments[inst]
                    // Pick the wave whose top key covers the note, first from A's list, then from B's
                    func pick(from start: Int) -> (entry: Int, nextList: Int) {
                        var x = start
                        while x + 12 <= table.count && table[x] < semitone && table[x] != 0x7F { x += 6 }
                        var end = x
                        while end + 12 <= table.count && table[end] != 0x7F { end += 6 }
                        return (x, min(end + 6, table.count - 6))
                    }
                    let a0 = pick(from: 0)
                    let b0 = pick(from: a0.nextList)
                    let aPtr = Int(table[a0.entry + 1]), aSize = Int(table[a0.entry + 2])
                    var aCtl = table[a0.entry + 3] & 0x0F
                    let bPtr = Int(table[b0.entry + 1]), bSize = Int(table[b0.entry + 2])
                    var bCtl = table[b0.entry + 3] & 0x0F
                    if song.stereo[voice] { aCtl |= 0x10; bCtl |= 0x10 }

                    let f = SoundSmithRenderer.frequency(semitone, shift: bank.compact[inst])
                    setFrequency(a, f); setFrequency(b, f)
                    setVolume(a, volume); setVolume(b, volume)
                    setPointer(a, aPtr); setPointer(b, bPtr)
                    setSize(a, aSize); setSize(b, bSize)
                    setControl(a, aCtl); setControl(b, bCtl)
                }
                rowOffset += 1
            }
            curRow += 1
            if curRow < 0x40 { return }
            curRow = 0
            curPat += 1
            if curPat < song.orders.count {
                rowOffset = song.orders[curPat]
            } else {
                stopped = true
            }
        }

        mutating func applyArpeggio() {
            for voice in 0..<14 where arpeggio[voice] != 0 {
                let a = arpeggio[voice]
                switch timer % 6 {
                case 1, 4: tone[voice] += a >> 4
                case 2, 5: tone[voice] += a & 0x0F
                default: tone[voice] -= (a >> 4) + (a & 0x0F)
                }
                let inst = curInst[voice]
                let f = SoundSmithRenderer.frequency(tone[voice], shift: inst < 16 ? bank.compact[inst] : 0)
                setFrequency(voice * 2, f)
                setFrequency(voice * 2 + 1, f)
            }
        }
    }

    // MARK: - Rendering

    /// Plays the song once and returns left and right channels at `docRate`
    static func render(song: Song, bank: Wavebank) -> (left: [Float], right: [Float]) {
        var machine = Machine(song: song, bank: bank)
        var left: [Float] = [], right: [Float] = []
        let maxFrames = Int(maxSeconds * docRate)
        while !machine.stopped && left.count < maxFrames {
            if left.count & 0x3FFF == 0 && Task.isCancelled { break }
            let (l, r) = machine.tick()
            left.append(max(-1, min(1, l)))
            right.append(max(-1, min(1, r)))
        }
        return (left, right)
    }
}
