//
//  SarvamEars.swift
//  SaathiKit
//
//  Sarvam's ears: a held turn is recorded, and Saaras is asked what was said.
//
//  This is the one place a learner's voice leaves the machine on the chain lane, and it happens
//  only when the configuration asks for it (`speech: sarvam`). `VoiceLaneReport` says so in words.
//  It exists because there is no other way to be heard in most Indian languages: Apple's
//  recogniser does not have them.
//
//  Nothing is sent while the keys are held. The turn is recorded here, and goes up as one WAV when
//  they are let go — which is also why no words appear as they are said.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// What the microphone gave for one turn.
public struct RecordedTurn: Equatable, Sendable {
    /// PCM16, mono, little-endian, at `SarvamEars.sampleRate`.
    public var pcm16: Data
    /// The loudest moment, 0…1. A turn that never rose above a whisper was a closed microphone.
    public var peak: Float

    public init(pcm16: Data = Data(), peak: Float = 0) {
        self.pcm16 = pcm16
        self.peak = peak
    }

    public var seconds: Double {
        Double(pcm16.count / MemoryLayout<Int16>.size) / SarvamEars.sampleRate
    }
}

/// The microphone, for one held turn. A protocol so the ears can be tested with no microphone.
public protocol TurnRecorder: Sendable {
    /// Asks for the microphone if nobody has yet. Throws when the answer is no.
    func prepare() async throws
    func start(onLevel: (@Sendable (Float) -> Void)?) throws
    /// Stops, and hands over what was recorded. Empty when nothing was being recorded.
    func stop() -> RecordedTurn
}

/// A plain `AVAudioEngine`, as the on-device ears use — not the realtime lane's voice-processing
/// one. An engine opened beside a live voice-processing engine records silence; by the time this
/// one opens, a realtime session that ran earlier has been torn down, which should be enough and
/// has not been tried. `SarvamEars` says so out loud if a turn comes back silent.
public final class MicrophoneTurnRecorder: TurnRecorder, @unchecked Sendable {

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: SarvamEars.sampleRate, channels: 1, interleaved: true)!

    private struct State {
        var engine: AVAudioEngine?
        var pcm16 = Data()
        var peak: Float = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func prepare() async throws {
        if Permissions.status(of: .microphone) == .granted { return }
        guard await Permissions.request(.microphone) == .granted else {
            throw VoiceError.notConfigured(
                "Saathi needs the microphone to hear you. Grant it in System Settings → Privacy & Security → Microphone.")
        }
    }

    public func start(onLevel: (@Sendable (Float) -> Void)?) throws {
        _ = stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: Self.format) else {
            throw VoiceError.audio("cannot convert \(hardware) to PCM16 at 16 kHz")
        }
        let box = ConverterBox(converter)

        input.installTap(onBus: 0, bufferSize: 2400, format: hardware) { [weak self] buffer, _ in
            let peak = SharedFrames.peak(buffer)
            let samples = Self.convert(buffer, mono: mono, with: box.converter)
            self?.state.withLock { state in
                state.pcm16.append(samples)
                state.peak = max(state.peak, peak)
            }
            onLevel?(InputLevel.level(of: buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        state.withLock { $0.engine = engine }
    }

    public func stop() -> RecordedTurn {
        // The tap comes off before the samples are taken, so the last buffer is in them.
        let engine = state.withLock { $0.engine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        return state.withLock { state in
            defer { state = State() }
            return RecordedTurn(pcm16: state.pcm16, peak: state.peak)
        }
    }

    /// One tap buffer as PCM16 mono at 16 kHz. The first channel only: a multi-channel input handed
    /// to `AVAudioConverter` for a downmix comes out as silence, which is the bug the realtime
    /// engine already found. Not `private`, so it can be tested with a buffer made by hand.
    static func convert(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat, with converter: AVAudioConverter) -> Data {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData?[0],
              let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = single.floatChannelData?[0] else { return Data() }
        target.update(from: source, count: Int(buffer.frameLength))
        single.frameLength = buffer.frameLength

        let ratio = format.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return single
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }
}

public final class SarvamEars: Ears, @unchecked Sendable {

    /// What Saaras asks for.
    public static let sampleRate: Double = 16_000
    /// Under this a turn was the keys being tapped, not a sentence.
    static let shortestTurn: TimeInterval = 0.3
    /// Under this the microphone gave nothing: the same line Dictate draws.
    static let silence: Float = 0.02
    /// Saaras takes thirty seconds a request; a longer turn goes up in pieces this long.
    static let longestPiece: TimeInterval = 28

    private let client: SarvamClient
    private let language: String
    private let recorder: any TurnRecorder

    /// `language`: Sarvam's code for it, "ml-IN".
    public init(client: SarvamClient, language: String, recorder: any TurnRecorder = MicrophoneTurnRecorder()) {
        self.client = client
        self.language = language
        self.recorder = recorder
    }

    public func prepare() async throws -> String {
        try await recorder.prepare()
        return "ready — Sarvam hears you (\(language))"
    }

    public func begin(_ feedback: EarsFeedback) async throws {
        try recorder.start(onLevel: feedback.onLevel)
    }

    public func finish() async throws -> String {
        let turn = recorder.stop()
        guard turn.seconds >= Self.shortestTurn else { return "" }
        // Not sent: Saaras would be asked to transcribe silence, and the person would be told it
        // did not catch that, when the truth is that nothing reached it.
        guard turn.peak >= Self.silence else {
            throw VoiceError.audio(
                "the microphone gave no sound. Check the input in Sound settings — and if Saathi has "
                + "only just switched to Sarvam, quit and reopen it.")
        }

        var heard: [String] = []
        for piece in Self.pieces(of: turn.pcm16) {
            let wav = WaveFile.wrap(pcm16: piece, sampleRate: Int(Self.sampleRate))
            let text = try await client.transcribe(wav: wav, language: language)
            if !text.isEmpty { heard.append(text) }
        }
        return heard.joined(separator: " ")
    }

    public func cancel() {
        _ = recorder.stop()
    }

    /// A turn cut into pieces Saaras will take. Cut on a sample, never through one; a word that
    /// straddles a cut may be heard badly, which is better than a long turn being refused whole.
    static func pieces(of pcm16: Data) -> [Data] {
        let longest = Int(longestPiece * sampleRate) * MemoryLayout<Int16>.size
        guard pcm16.count > longest else { return pcm16.isEmpty ? [] : [pcm16] }
        var pieces: [Data] = []
        var start = pcm16.startIndex
        while start < pcm16.endIndex {
            let end = min(start + longest, pcm16.endIndex)
            pieces.append(pcm16.subdata(in: start..<end))
            start = end
        }
        return pieces
    }
}
