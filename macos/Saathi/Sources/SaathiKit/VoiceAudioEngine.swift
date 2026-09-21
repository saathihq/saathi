//
//  VoiceAudioEngine.swift
//  SaathiKit
//
//  Microphone in, speaker out, at the one format both voice lanes want: PCM16 mono 24 kHz.
//
//  Ported from OpenClicky's `RealtimeAudioEngine` (openclicky@21d41f9). It is the piece worth
//  carrying over verbatim, for two reasons:
//
//  1. Apple's voice-processing unit gives acoustic echo cancellation, which is what lets the
//     microphone stay open while Saathi is talking. Without it a companion has to mute itself to
//     listen, and someone who needs to interrupt — the exact person this is being built for —
//     cannot. Getting that unit configured without silencing the user's music took a while.
//  2. It carries a fixed data race that cost real time to find. The tap runs on CoreAudio's render
//     thread while teardown runs on the audio queue; reading the converter off `self` in the tap
//     races teardown nilling it, and under the Thread Sanitizer the process aborts. The fix is the
//     `MicrophoneCapture` snapshot below. Re-deriving that from scratch would have meant finding
//     the same bug twice.
//
//  Deliberately NOT ported: anything that knew about screenshots, the cursor, or an agent
//  subprocess. This class knows about audio.
//

@preconcurrency import AVFoundation
import Foundation
import os

public enum VoiceError: LocalizedError, Equatable {
    case audio(String)
    case notConfigured(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .audio(detail): return "audio: \(detail)"
        case let .notConfigured(detail): return detail
        case let .transport(detail): return "voice transport: \(detail)"
        }
    }
}

/// A local value handed to a `@Sendable` callback that runs synchronously on the calling thread.
/// Narrow on purpose: `AVAudioPCMBuffer` is not `Sendable`, and the one place that matters is the
/// converter block below, which never outlives the call that installs it.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Every engine call happens on `queue`, never on the main thread: CoreAudio's first-time setup
/// hops synchronously to the main queue, so configuring the engine from a main-actor task
/// deadlocks the app.
///
/// Two threads own parts of this class and neither of them is the main one, so it is `nonisolated`
/// on purpose. Under a main-actor-by-default build setting every stored property below would be
/// implicitly main-actor isolated while in fact being touched from `queue` and from CoreAudio's
/// render thread — a claim the compiler does not check, and which in the predecessor produced 53
/// warnings that said nothing about which accesses were actually unsafe.
///
/// The contract: everything private belongs to `queue`, except `microphoneCapture`, which is the
/// one piece the render thread reads and is therefore behind a lock.
public nonisolated final class VoiceAudioEngine: @unchecked Sendable {
    /// Both lanes speak PCM16 mono at 24 kHz — it is what OpenAI's realtime socket wants and it is
    /// a fine input format for on-device speech recognition, so there is one format, not two.
    public static let sampleRate: Double = 24_000

    private static let pcm16Format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Everything the render thread needs, as one immutable unit it can copy out in a single locked
    /// read. Published by `configure`, dropped by `tearDown`; a tap already in flight keeps its own
    /// reference alive, so teardown cannot pull the converter out from under it.
    private final class MicrophoneCapture: @unchecked Sendable {
        let converter: AVAudioConverter
        let monoFormat: AVAudioFormat
        let onFrame: (Data, Double) -> Void

        init(converter: AVAudioConverter, monoFormat: AVAudioFormat, onFrame: @escaping (Data, Double) -> Void) {
            self.converter = converter
            self.monoFormat = monoFormat
            self.onFrame = onFrame
        }
    }

    private let queue = DispatchQueue(label: "dev.saathi.voice.audio")
    /// `os_unfair_lock` rather than `NSLock`: it donates priority, so the app thread holding it for
    /// three pointer loads cannot invert the priority of the real-time audio thread waiting on it.
    private let microphoneCapture = OSAllocatedUnfairLock<MicrophoneCapture?>(initialState: nil)
    private var onMicrophoneFrame: ((Data, Double) -> Void)?
    private var onPlaybackActiveChanged: ((Bool) -> Void)?
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var isRunning = false
    private var queuedBuffers = 0
    private var tapCount = 0
    private var framesOut = 0

    public init() {}

    /// Both callbacks are read from `queue` and from the audio thread, so they are installed on
    /// `queue` rather than assigned directly. Call before `start()`.
    public func setCallbacks(
        onMicrophoneFrame: @escaping (Data, Double) -> Void,
        onPlaybackActiveChanged: @escaping (Bool) -> Void
    ) {
        queue.sync {
            self.onMicrophoneFrame = onMicrophoneFrame
            self.onPlaybackActiveChanged = onPlaybackActiveChanged
        }
    }

    /// One line of capture statistics, for bug reports and the smoke path.
    public func debugSummary() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning:
                    "taps \(self.tapCount), frames out \(self.framesOut), engine running \(self.engine.isRunning)")
            }
        }
    }

    /// Starts capture and playback; returns a one-line description of the configuration.
    public func start() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                if self.isRunning {
                    if !self.engine.isRunning {
                        do { try self.engine.start() } catch { continuation.resume(throwing: error); return }
                    }
                    continuation.resume(returning: "audio already running")
                    return
                }
                do {
                    var description: String
                    do {
                        description = try self.configure(voiceProcessing: true)
                    } catch {
                        // Echo cancellation is a strong preference, not a requirement. Losing it
                        // means Saathi has to stop talking to listen; failing to start means it
                        // cannot listen at all. Say which happened rather than swallowing it.
                        self.tearDown()
                        description = try self.configure(voiceProcessing: false)
                        description += " (voice processing unavailable: \(error.localizedDescription))"
                    }
                    self.isRunning = true
                    continuation.resume(returning: description)
                } catch {
                    self.tearDown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        queue.async { self.tearDown() }
    }

    /// Releases the microphone (the menu bar indicator goes off) but keeps the graph configured so
    /// the next `start()` is a fast engine restart instead of a full setup.
    public func pause() {
        queue.async {
            guard self.isRunning, self.engine.isRunning else { return }
            self.playerNode.stop()
            self.queuedBuffers = 0
            self.engine.stop()
        }
    }

    /// Tears the whole graph down, voice-processing unit included, so nothing of ours touches the
    /// audio system between turns.
    public func release() {
        queue.async {
            guard self.isRunning else { return }
            self.tearDown()
        }
    }

    /// `release()`, but returns once the graph is actually gone.
    public func releaseNow() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.isRunning { self.tearDown() }
                continuation.resume()
            }
        }
    }

    /// Queue assistant audio for playback. PCM16 mono at `sampleRate`.
    ///
    /// Restarts the engine if it is paused, which brings the microphone tap up with it: the
    /// graph is one engine. The session pauses it again when playback drains (see
    /// `onPlaybackActiveChanged`); left running, the microphone light stayed on between turns.
    public func enqueue(pcm16 data: Data) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            if !self.engine.isRunning {
                do { try self.engine.start() } catch { return }
            }
            let sampleCount = data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat,
                                                frameCapacity: AVAudioFrameCount(sampleCount)),
                  let floatChannel = buffer.floatChannelData?[0] else { return }
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<sampleCount { floatChannel[index] = Float(samples[index]) / 32768.0 }
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            self.queuedBuffers += 1
            if self.queuedBuffers == 1 { self.onPlaybackActiveChanged?(true) }
            self.playerNode.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.queuedBuffers = max(0, self.queuedBuffers - 1)
                    if self.queuedBuffers == 0 { self.onPlaybackActiveChanged?(false) }
                }
            }
            if !self.playerNode.isPlaying { self.playerNode.play() }
        }
    }

    /// Drop everything queued. This is barge-in: the learner started talking, so Saathi stops.
    public func flushPlayback() {
        queue.async {
            guard self.isRunning else { return }
            self.playerNode.stop()
            self.queuedBuffers = 0
            self.onPlaybackActiveChanged?(false)
            if self.engine.isRunning { self.playerNode.play() }
        }
    }

    // MARK: Internals (audio queue only)

    private func configure(voiceProcessing: Bool) throws -> String {
        let inputNode = engine.inputNode
        let outputNode = engine.outputNode
        var notes: [String] = []
        if voiceProcessing {
            try inputNode.setVoiceProcessingEnabled(true)
            // Apple's voice-processing unit ducks every other app's audio while it runs, which in
            // the predecessor meant the user's music went quiet the moment the companion listened.
            // Keep echo cancellation, drop the ducking to its minimum, skip "advanced" ducking.
            //
            // The knob to do that is macOS 14+. On 13 the ducking stays at the system default and
            // there is nothing to be done about it, so say so in the description rather than
            // raising the deployment target — echo cancellation is the part that matters, and it
            // is available on 13.
            if #available(macOS 14.0, *) {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false, duckingLevel: .min)
                notes.append("other-audio ducking min")
            } else {
                notes.append("other-audio ducking at system default (needs macOS 14)")
            }
        }
        engine.attach(playerNode)
        // With voice processing on, the output unit only initialises when the mixer → output link
        // is made explicitly at the hardware format before the player is connected. `connect`
        // raises an uncatchable ObjC exception on an invalid format, so validate first.
        let outputFormat = [outputNode.outputFormat(forBus: 0), outputNode.inputFormat(forBus: 0)]
            .first { $0.sampleRate > 0 && $0.channelCount > 0 }
        if let outputFormat {
            engine.connect(engine.mainMixerNode, to: outputNode, format: outputFormat)
            notes.append("output \(Int(outputFormat.sampleRate)) Hz × \(outputFormat.channelCount) ch")
        } else {
            engine.connect(engine.mainMixerNode, to: outputNode, format: nil)
            notes.append("output format unknown, engine default")
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.playbackFormat)

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        // The voice-processing input reports 5 identical channels; AVAudioConverter turns a
        // multi-channel → mono conversion into silence, so channel 0 is copied into a mono buffer
        // first and only the sample rate / sample format are converted.
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: monoFormat, to: Self.pcm16Format) else {
            throw VoiceError.audio("cannot convert \(hardwareFormat) to PCM16 24 kHz")
        }
        self.monoFormat = monoFormat
        self.converter = converter
        if let onMicrophoneFrame {
            microphoneCapture.withLock {
                $0 = MicrophoneCapture(converter: converter, monoFormat: monoFormat, onFrame: onMicrophoneFrame)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleMicrophoneBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        return "audio running: input \(Int(hardwareFormat.sampleRate)) Hz × \(hardwareFormat.channelCount) ch, "
            + "\(notes.joined(separator: ", ")), voice processing \(voiceProcessing ? "on" : "off")"
    }

    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        microphoneCapture.withLock { $0 = nil }
        converter = nil
        monoFormat = nil
        queuedBuffers = 0
        isRunning = false
    }

    /// Audio thread: convert to PCM16 mono 24 kHz and hand the bytes on.
    ///
    /// Everything this touches on `self` is either the capture snapshot (behind the lock) or a
    /// counter bumped on `queue`. Reading `converter` / `monoFormat` / `onMicrophoneFrame` off
    /// `self` here — as the predecessor did — races `tearDown()` nilling them on `queue`; the
    /// Thread Sanitizer reports it and aborts the process. `VoiceAudioEngineConcurrencyTests`
    /// pins that down.
    ///
    /// Not `private` so that test can drive it directly from a background thread.
    func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { self.tapCount += 1 }
        guard let capture = microphoneCapture.withLock({ $0 }) else { return }
        let converter = capture.converter
        let monoFormat = capture.monoFormat
        let onMicrophoneFrame = capture.onFrame
        let mono: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            mono = buffer
        } else {
            guard let copy = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData?[0],
                  let target = copy.floatChannelData?[0] else { return }
            target.update(from: source, count: Int(buffer.frameLength))
            copy.frameLength = buffer.frameLength
            mono = copy
        }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.pcm16Format, frameCapacity: capacity) else { return }
        var conversionError: NSError?
        // `convert` calls this synchronously and only on this thread, and `mono` is a local this
        // frame owns — but the block is typed `@Sendable`, so the buffer is passed through a box
        // rather than captured, which is both true to what happens and quiet at compile time.
        let input = UncheckedBox(mono)
        var consumedInput = false
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return input.value
        }
        guard conversionError == nil, converted.frameLength > 0,
              let channel = converted.int16ChannelData else { return }
        let data = Data(bytes: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        let level = Self.rmsLevel(of: buffer)
        let frameCount = Int(converted.frameLength)
        queue.async { self.framesOut += frameCount }
        onMicrophoneFrame(data, level)
    }

    /// 0…1, for a level meter. Loudness is the one piece of feedback that works when someone cannot
    /// see the screen and cannot hear themselves — "is it hearing me at all".
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, Double(rms) * 4)
    }
}
