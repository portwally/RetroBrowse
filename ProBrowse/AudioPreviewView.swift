//
//  AudioPreviewView.swift
//  ProBrowse
//
//  Plays Apple IIgs sounds and music in the inspector
//

import SwiftUI
import Combine
import AVFoundation

/// Plays one sound at a time and reports its position
@MainActor
final class AudioPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var midiPlayer: AVMIDIPlayer?
    private var timer: Timer?
    private var startedAt: Date?
    /// Bumped on every play/stop so a finished buffer from an older play is ignored
    private var generation = 0

    init() {
        engine.attach(node)
    }

    /// The buffer for the last sound played, so pressing Play again doesn't copy it again
    private var cachedBuffer: (id: UUID, buffer: AVAudioPCMBuffer)?

    func play(_ sound: DecodedSound) {
        if let cached = cachedBuffer, cached.id == sound.id {
            play(cached.buffer)
            return
        }
        let channels: [[Float]] = sound.right.map { [sound.samples, $0] } ?? [sound.samples]
        let frames = sound.samples.count
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sound.sampleRate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            errorMessage = "This sound can't be played."
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (i, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { src in
                buffer.floatChannelData![i].update(from: src.baseAddress!, count: min(frames, channel.count))
            }
        }
        cachedBuffer = (sound.id, buffer)
        play(buffer)
    }

    /// AIFF / AIFF-C through AVAudioFile, which needs a file on disk
    func playAudioFile(_ data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retrobrowse-preview-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                errorMessage = "This AIFF file can't be played."
                return
            }
            try file.read(into: buffer)
            play(buffer)
        } catch {
            errorMessage = "This AIFF file can't be played."
        }
    }

    func playMIDI(_ data: Data) {
        stop()
        do {
            let player = try AVMIDIPlayer(data: data, soundBankURL: nil)
            player.prepareToPlay()
            midiPlayer = player
            duration = player.duration
            let gen = generation
            player.play { [weak self] in
                let owner = self
                Task { @MainActor in
                    guard let self = owner, self.generation == gen else { return }
                    self.finish()
                }
            }
            begin()
        } catch {
            errorMessage = "This MIDI file can't be played."
        }
    }

    func stop() {
        generation += 1
        node.stop()
        if engine.isRunning { engine.stop() }
        midiPlayer?.stop()
        midiPlayer = nil
        finish()
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        do {
            try engine.start()
        } catch {
            errorMessage = "Audio output isn't available."
            return
        }
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let gen = generation
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            let owner = self
            Task { @MainActor in
                guard let self = owner, self.generation == gen else { return }
                self.stop()
            }
        }
        node.play()
        begin()
    }

    private func begin() {
        errorMessage = nil
        isPlaying = true
        position = 0
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            let owner = self
            Task { @MainActor in
                guard let self = owner, let start = self.startedAt else { return }
                self.position = min(Date().timeIntervalSince(start), self.duration)
            }
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isPlaying = false
        position = 0
    }
}

struct AudioPreviewView: View {
    let entry: DiskCatalogEntry
    var siblings: [DiskCatalogEntry] = []

    @StateObject private var player = AudioPreviewPlayer()
    @State private var selectedID: UUID?

    /// Decoded once when the view appears; decoding again on every redraw would be slow
    @State private var document: SoundDocument?

    var body: some View {
        VStack(spacing: 0) {
            switch document {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .samples(let sounds):
                samplesView(sounds)
            case .midi(let data):
                singleView(title: "Standard MIDI file", detail: "Played with the built-in General MIDI instruments") {
                    player.playMIDI(data)
                }
            case .audioFile(let data):
                singleView(title: "Audio IFF", detail: "AIFF / AIFF-C sound") { player.playAudioFile(data) }
            case .unsupported(let message):
                VStack(spacing: 12) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(message)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .task {
            let e = entry
            var companions: [String: Data] = [:]
            for s in siblings where s.id != e.id && !s.isDirectory { companions[s.name.uppercased()] = s.data }
            let folder = companions
            // Rendering a song can take a while; stop it if the inspector closes first
            let work = Task.detached {
                AppleIIgsSoundDecoder.decode(fileType: e.fileType, auxType: e.auxType, data: e.data,
                                             resourceFork: e.resourceForkData, name: e.name, companions: folder)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { document = result }
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Sampled sounds

    @ViewBuilder
    private func samplesView(_ sounds: [DecodedSound]) -> some View {
        let current = sounds.first { $0.id == selectedID } ?? sounds[0]
        VStack(spacing: 0) {
            controls(title: current.name, detail: current.detail, canPlay: true) { player.play(current) }
            WaveformView(envelope: current.envelope)
                .equatable()
                .overlay(alignment: .leading) {
                    // The playhead moves on its own so the waveform isn't redrawn while playing
                    GeometryReader { geo in
                        if player.isPlaying && player.duration > 0 {
                            Rectangle()
                                .fill(Color.primary)
                                .frame(width: 1.5)
                                .offset(x: geo.size.width * CGFloat(player.position / player.duration))
                        }
                    }
                }
                .frame(height: 140)
                .padding(.horizontal)
                .padding(.bottom)
            if sounds.count > 1 {
                Divider()
                List(sounds, selection: Binding(get: { current.id }, set: { id in
                    selectedID = id
                    if let id, let sound = sounds.first(where: { $0.id == id }) { player.play(sound) }
                })) { sound in
                    HStack {
                        Text(sound.name)
                        Spacer()
                        Text(String(format: "%.2f s", sound.duration))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .tag(sound.id)
                }
            } else {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func singleView(title: String, detail: String, play: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            controls(title: title, detail: detail, canPlay: true, play: play)
            Spacer()
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(title: String, detail: String, canPlay: Bool, play: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    player.isPlaying ? player.stop() : play()
                } label: {
                    Image(systemName: player.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Stop (Space)" : "Play (Space)")

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(timeString(player.position)) / \(timeString(player.duration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .opacity(player.duration > 0 ? 1 : 0)
            }
            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .padding()
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
    }
}

/// Draws a sound's min/max envelope
struct WaveformView: View, Equatable {
    let envelope: [Float]

    var body: some View {
        Canvas { context, size in
            let columns = envelope.count / 2
            guard columns > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            for c in 0..<columns {
                let x = (CGFloat(c) + 0.5) * size.width / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: mid - CGFloat(envelope[c * 2 + 1]) * mid))
                path.addLine(to: CGPoint(x: x, y: mid - CGFloat(envelope[c * 2]) * mid + 0.5))
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: max(1, size.width / CGFloat(columns)))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
