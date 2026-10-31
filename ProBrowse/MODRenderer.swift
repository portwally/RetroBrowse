//
//  MODRenderer.swift
//  ProBrowse
//
//  Renders Amiga-style tracker modules (ProTracker / NoiseTracker, as played on the
//  Apple IIgs by NoiseTracker GS and others) to stereo PCM.
//
//  Source: "Noisetracker/Soundtracker/Protracker Module Format, 4th Revision"
//  (Andrew Scott et al.), https://www.aes.id.au/modformat.html
//

import Foundation

nonisolated enum MODRenderer {

    static let outputRate = 44100.0
    /// Songs are rendered up front, so very long or endless ones are cut off here
    static let maxSeconds = 600.0
    private static let palClock = 7093789.2

    struct Sample {
        var name: String
        var data: [Float]
        var finetune: Int
        var volume: Int
        var loopStart: Int
        var loopLength: Int
    }

    struct Module {
        var title: String
        var channels: Int
        var samples: [Sample]   // index 0 is unused so sample numbers can index directly
        var order: [Int]
        var patterns: [[UInt8]] // 64 rows * channels * 4 bytes each
    }

    // MARK: - Detection

    /// Channel count from the format tag at offset 1080, or nil if this isn't a module
    static func channelCount(_ data: Data) -> Int? {
        guard data.count >= 1084 else { return nil }
        let tag = String(data: data.subdata(in: data.startIndex + 1080..<data.startIndex + 1084), encoding: .ascii) ?? ""
        switch tag {
        case "M.K.", "M!K!", "FLT4", "4CHN": return 4
        case "6CHN": return 6
        case "8CHN", "FLT8", "OCTA", "CD81": return 8
        default:
            // "xxCH" for 10 or more channels
            if tag.hasSuffix("CH"), let n = Int(tag.prefix(2)), (2...32).contains(n) { return n }
            return nil
        }
    }

    static func isModule(_ data: Data) -> Bool { channelCount(data) != nil }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Module? {
        guard let channels = channelCount(data) else { return nil }
        let bytes = [UInt8](data)
        func be16(_ o: Int) -> Int { Int(bytes[o]) << 8 | Int(bytes[o + 1]) }
        func text(_ o: Int, _ n: Int) -> String {
            let raw = bytes[o..<o + n].prefix { $0 != 0 }.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x20 }
            return String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        var headers: [(name: String, length: Int, finetune: Int, volume: Int, loopStart: Int, loopLength: Int)] = []
        for i in 0..<31 {
            let o = 20 + i * 30
            var fine = Int(bytes[o + 24] & 0x0F)
            if fine > 7 { fine -= 16 }
            headers.append((text(o, 22), be16(o + 22) * 2, fine, min(64, Int(bytes[o + 25])),
                            be16(o + 26) * 2, be16(o + 28) * 2))
        }
        let songLength = max(1, min(128, Int(bytes[950])))
        let order = (0..<songLength).map { Int(bytes[952 + $0]) }
        let patternCount = (bytes[952..<1080].max().map(Int.init) ?? 0) + 1
        let patternSize = 64 * channels * 4
        var p = 1084
        var patterns: [[UInt8]] = []
        for _ in 0..<patternCount {
            guard p + patternSize <= bytes.count else { return nil }
            patterns.append(Array(bytes[p..<p + patternSize]))
            p += patternSize
        }

        var samples = [Sample(name: "", data: [], finetune: 0, volume: 0, loopStart: 0, loopLength: 0)]
        for h in headers {
            let length = max(0, min(h.length, bytes.count - p))
            let pcm = (0..<length).map { Float(Int8(bitPattern: bytes[p + $0])) / 128 }
            p += length
            var loopStart = h.loopStart, loopLength = h.loopLength
            if loopLength <= 2 || loopStart + 2 > length {
                loopLength = 0
            } else if loopStart + loopLength > length {
                loopLength = length - loopStart
            }
            loopStart = loopLength > 0 ? loopStart : 0
            samples.append(Sample(name: h.name, data: pcm, finetune: h.finetune, volume: h.volume,
                                  loopStart: loopStart, loopLength: loopLength))
        }
        return Module(title: text(0, 20), channels: channels, samples: samples, order: order, patterns: patterns)
    }

    // MARK: - Playback state

    private struct Channel {
        var sample = 0
        var pos = 0.0
        var playing = false
        var period = 0
        var volume = 0
        var finetune = 0
        // effect memory
        var portaTarget = 0
        var portaSpeed = 0
        var vibratoSpeed = 0, vibratoDepth = 0, vibratoPos = 0
        var tremoloSpeed = 0, tremoloDepth = 0, tremoloPos = 0
        var offsetMemory = 0
        var loopRow = 0, loopCount = 0
        // per-tick output
        var outPeriod = 0
        var outVolume = 0
    }

    private static let sine: [Int] = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
                                      255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24]

    /// Standard periods for finetune 0, octaves 1-3
    private static let basePeriods = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
                                      428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
                                      214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]

    /// Period for a note index at a finetune (each step is 1/8 semitone)
    private static func period(note: Int, finetune: Int) -> Int {
        let base = Double(basePeriods[max(0, min(35, note))])
        return Int((base * pow(2, -Double(finetune) / 96)).rounded())
    }

    private static func noteIndex(forPeriod p: Int) -> Int {
        var best = 0
        for (i, v) in basePeriods.enumerated() where abs(v - p) < abs(basePeriods[best] - p) { best = i }
        return best
    }

    // MARK: - Rendering

    /// Plays the song once (stopping when it loops back) and returns left and right channels
    static func render(_ module: Module) -> (left: [Float], right: [Float]) {
        var chans = [Channel](repeating: Channel(), count: module.channels)
        var left: [Float] = [], right: [Float] = []
        let maxFrames = Int(maxSeconds * outputRate)
        left.reserveCapacity(min(maxFrames, Int(outputRate) * 180))
        right.reserveCapacity(min(maxFrames, Int(outputRate) * 180))

        var speed = 6, tempo = 125
        var orderIndex = 0, row = 0
        var visited = Set<Int>()

        song: while orderIndex < module.order.count && left.count < maxFrames && !Task.isCancelled {
            let key = orderIndex << 8 | row
            if visited.contains(key) { break }   // the song has looped
            visited.insert(key)

            let pattern = module.patterns[min(module.order[orderIndex], module.patterns.count - 1)]
            var breakRow: Int? = nil, jumpOrder: Int? = nil
            var patternDelay = 0
            var loopJump: Int? = nil

            // Row start: read notes and run first-tick effects
            var cells: [(sample: Int, period: Int, effect: Int, param: Int)] = []
            for c in 0..<module.channels {
                let o = (row * module.channels + c) * 4
                let b0 = Int(pattern[o]), b1 = Int(pattern[o + 1]), b2 = Int(pattern[o + 2]), b3 = Int(pattern[o + 3])
                cells.append(((b0 & 0xF0) | (b2 >> 4), (b0 & 0x0F) << 8 | b1, b2 & 0x0F, b3))
            }

            for c in 0..<module.channels {
                let cell = cells[c]
                var ch = chans[c]
                let x = cell.param >> 4, y = cell.param & 0x0F

                if cell.sample > 0 && cell.sample < module.samples.count {
                    ch.sample = cell.sample
                    ch.volume = module.samples[cell.sample].volume
                    ch.finetune = module.samples[cell.sample].finetune
                }
                if cell.effect == 0xE && x == 5 { ch.finetune = y > 7 ? y - 16 : y }

                let delayed = cell.effect == 0xE && x == 0xD && y > 0
                if cell.period > 0 {
                    let tuned = period(note: noteIndex(forPeriod: cell.period), finetune: ch.finetune)
                    if cell.effect == 3 || cell.effect == 5 {
                        ch.portaTarget = tuned
                    } else if !delayed {
                        ch.period = tuned
                        ch.pos = 0
                        ch.playing = ch.sample > 0
                        ch.vibratoPos = 0
                        ch.tremoloPos = 0
                    }
                }

                switch cell.effect {
                case 3:
                    if cell.param > 0 { ch.portaSpeed = cell.param }
                case 4:
                    if x > 0 { ch.vibratoSpeed = x }
                    if y > 0 { ch.vibratoDepth = y }
                case 7:
                    if x > 0 { ch.tremoloSpeed = x }
                    if y > 0 { ch.tremoloDepth = y }
                case 9:
                    if cell.param > 0 { ch.offsetMemory = cell.param * 256 }
                    if cell.period > 0 { ch.pos = Double(ch.offsetMemory) }
                case 0xB:
                    jumpOrder = cell.param
                case 0xC:
                    ch.volume = min(64, cell.param)
                case 0xD:
                    breakRow = min(63, x * 10 + y)
                case 0xE:
                    switch x {
                    case 1: ch.period = max(113, ch.period - y)
                    case 2: ch.period = min(856 * 2, ch.period + y)
                    case 6:
                        if y == 0 { ch.loopRow = row }
                        else if ch.loopCount == 0 { ch.loopCount = y; loopJump = ch.loopRow }
                        else { ch.loopCount -= 1; if ch.loopCount > 0 { loopJump = ch.loopRow } }
                    case 0xA: ch.volume = min(64, ch.volume + y)
                    case 0xB: ch.volume = max(0, ch.volume - y)
                    case 0xE: patternDelay = y
                    default: break
                    }
                case 0xF:
                    if cell.param == 0 { break }
                    if cell.param < 32 { speed = cell.param } else { tempo = cell.param }
                default: break
                }
                ch.outPeriod = ch.period
                ch.outVolume = ch.volume
                chans[c] = ch
            }

            let ticks = speed * (patternDelay + 1)
            for tick in 0..<ticks {
                let t = tick % speed
                if tick > 0 {
                    for c in 0..<module.channels {
                        applyTickEffects(&chans[c], cell: cells[c], tick: t, module: module)
                    }
                } else {
                    for c in 0..<module.channels { applyVibratoTremolo(&chans[c], cell: cells[c], advance: false) }
                }
                mixTick(&chans, module: module, tempo: tempo, left: &left, right: &right)
                if left.count >= maxFrames { break song }
            }

            // Advance to the next row
            if let target = loopJump {
                row = target
                visited = visited.filter { $0 >> 8 != orderIndex }
                continue
            }
            if jumpOrder != nil || breakRow != nil {
                let nextOrder = jumpOrder ?? orderIndex + 1
                orderIndex = nextOrder
                row = breakRow ?? 0
            } else {
                row += 1
                if row >= 64 { row = 0; orderIndex += 1 }
            }
        }

        // Blend a quarter of each side into the other; hard Amiga panning is tiring on headphones
        for i in 0..<left.count {
            let l = left[i], r = right[i]
            left[i] = l * 0.75 + r * 0.25
            right[i] = r * 0.75 + l * 0.25
        }

        // Short fade-out so a cut-off song doesn't end with a click
        let fade = min(left.count, Int(outputRate * 0.05))
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            left[left.count - fade + i] *= 1 - g
            right[right.count - fade + i] *= 1 - g
        }
        return (left, right)
    }

    private static func applyTickEffects(_ ch: inout Channel, cell: (sample: Int, period: Int, effect: Int, param: Int),
                                         tick: Int, module: Module) {
        let x = cell.param >> 4, y = cell.param & 0x0F
        ch.outPeriod = ch.period
        ch.outVolume = ch.volume
        switch cell.effect {
        case 0:
            if cell.param != 0 && ch.period > 0 {
                let shift = [0, x, y][tick % 3]
                let note = noteIndex(forPeriod: ch.period)
                ch.outPeriod = period(note: min(35, note + shift), finetune: ch.finetune)
            }
        case 1: ch.period = max(113, ch.period - cell.param); ch.outPeriod = ch.period
        case 2: ch.period = min(856 * 2, ch.period + cell.param); ch.outPeriod = ch.period
        case 3: portamento(&ch)
        case 5: portamento(&ch); volumeSlide(&ch, x, y)
        case 6: volumeSlide(&ch, x, y)
        case 0xA: volumeSlide(&ch, x, y)
        case 0xE:
            switch x {
            case 9: if y > 0 && tick % y == 0 { ch.pos = 0; ch.playing = ch.sample > 0 }
            case 0xC: if tick == y { ch.volume = 0; ch.outVolume = 0 }
            case 0xD:
                if tick == y && cell.period > 0 {
                    ch.period = period(note: noteIndex(forPeriod: cell.period), finetune: ch.finetune)
                    ch.outPeriod = ch.period
                    ch.pos = 0
                    ch.playing = ch.sample > 0
                }
            default: break
            }
        default: break
        }
        applyVibratoTremolo(&ch, cell: cell, advance: true)
    }

    private static func applyVibratoTremolo(_ ch: inout Channel, cell: (sample: Int, period: Int, effect: Int, param: Int),
                                            advance: Bool) {
        if cell.effect == 4 || cell.effect == 6 {
            let delta = sine[ch.vibratoPos & 31] * ch.vibratoDepth / 128
            ch.outPeriod = ch.period + ((ch.vibratoPos & 32) != 0 ? -delta : delta)
            if advance { ch.vibratoPos = (ch.vibratoPos + ch.vibratoSpeed) & 63 }
        }
        if cell.effect == 7 {
            let delta = sine[ch.tremoloPos & 31] * ch.tremoloDepth / 64
            ch.outVolume = max(0, min(64, ch.volume + ((ch.tremoloPos & 32) != 0 ? -delta : delta)))
            if advance { ch.tremoloPos = (ch.tremoloPos + ch.tremoloSpeed) & 63 }
        }
    }

    private static func portamento(_ ch: inout Channel) {
        guard ch.portaTarget > 0 else { return }
        if ch.period < ch.portaTarget { ch.period = min(ch.portaTarget, ch.period + ch.portaSpeed) }
        else if ch.period > ch.portaTarget { ch.period = max(ch.portaTarget, ch.period - ch.portaSpeed) }
        ch.outPeriod = ch.period
    }

    private static func volumeSlide(_ ch: inout Channel, _ x: Int, _ y: Int) {
        ch.volume = x > 0 ? min(64, ch.volume + x) : max(0, ch.volume - y)
        ch.outVolume = ch.volume
    }

    /// Mixes one tick (2.5 / tempo seconds) of all channels; Amiga layout is L R R L
    private static func mixTick(_ chans: inout [Channel], module: Module, tempo: Int,
                                left: inout [Float], right: inout [Float]) {
        let frames = Int(outputRate * 2.5 / Double(max(32, tempo)))
        let start = left.count
        left.append(contentsOf: repeatElement(0, count: frames))
        right.append(contentsOf: repeatElement(0, count: frames))
        let gain: Float = 1.0 / Float(max(2, module.channels / 2)) * 0.8

        for c in 0..<chans.count {
            var ch = chans[c]
            guard ch.playing, ch.outPeriod > 0, ch.sample < module.samples.count else { continue }
            let s = module.samples[ch.sample]
            guard !s.data.isEmpty else { continue }
            let step = palClock / Double(2 * max(ch.outPeriod, 28)) / outputRate
            let vol = Float(ch.outVolume) / 64 * gain
            let isLeft = (c % 4 == 0 || c % 4 == 3)
            let loopEnd = s.loopStart + s.loopLength
            for i in 0..<frames {
                var idx = Int(ch.pos)
                if s.loopLength > 0 {
                    if idx >= loopEnd {
                        ch.pos = Double(s.loopStart) + (ch.pos - Double(loopEnd)).truncatingRemainder(dividingBy: Double(s.loopLength))
                        idx = Int(ch.pos)
                    }
                } else if idx >= s.data.count {
                    ch.playing = false
                    break
                }
                let v = s.data[min(idx, s.data.count - 1)] * vol
                if isLeft { left[start + i] += v } else { right[start + i] += v }
                ch.pos += step
            }
            chans[c] = ch
        }
    }
}
