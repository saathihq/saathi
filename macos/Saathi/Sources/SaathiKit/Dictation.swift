//
//  Dictation.swift
//  SaathiKit
//
//  The Dictate shortcut: hold fn and control, speak, let go, and what was said is typed into
//  whatever app is in front. Nothing is sent to a model and nothing leaves this Mac — the
//  recogniser is Apple's, on-device only — because dictating into a document is not a
//  conversation with Saathi and should not cost one.
//
//  Typing is a paste: the text goes on the clipboard, command-V is posted, and the clipboard is
//  put back as it was. Posting keystrokes one by one would be slower, trip over keyboard layouts,
//  and set off autocomplete in half the apps it lands in.
//

import AppKit
import AVFoundation
import Foundation
import os
import Speech

/// A shared microphone's frames — PCM16 mono at `VoiceAudioEngine.sampleRate` — as a buffer.
enum SharedFrames {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioEngine.sampleRate, channels: 1, interleaved: true)!

    static func buffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let target = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            if let source = raw.bindMemory(to: Int16.self).baseAddress { target.update(from: source, count: Int(frames)) }
        }
        buffer.frameLength = frames
        return buffer
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(Float(samples[index]) / 32768)) }
        }
        return peak
    }
}

/// `AVAudioConverter` is not `Sendable`; each one is only ever used from the one audio callback
/// that owns it, one buffer at a time.
final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    init(_ converter: AVAudioConverter) { self.converter = converter }
}

/// One way of turning a held key's worth of speech into text.
protocol DictationEngine: AnyObject, Sendable {
    func begin(language: String, microphone: (any SharedMicrophone)?) async throws
    func end() async -> String
    func cancel()
    var lastReport: String { get }
    var loudest: Float { get }
}

/// Dictate's front: Apple's current dictation model where the system has it (macOS 26 and later),
/// the older recogniser everywhere else. Both are on-device only.
public final class Dictation: @unchecked Sendable {

    private let active = OSAllocatedUnfairLock<(any DictationEngine)?>(initialState: nil)
    private let legacy = LegacyDictation()
    private let modern: AnyObject? = {
        if #available(macOS 26, *) { return ModernDictation() }
        return nil
    }()

    public init() {}

    private var engine: any DictationEngine {
        if #available(macOS 26, *), let modern = modern as? ModernDictation { return modern }
        return legacy
    }

    /// `microphone`: the voice session's, when it can share one — see `SharedMicrophone` for why a
    /// second microphone of dictation's own is only the fallback.
    public func begin(language: String, microphone: (any SharedMicrophone)? = nil) async throws {
        cancel()
        let engine = self.engine
        active.withLock { $0 = engine }
        try await engine.begin(language: language, microphone: microphone)
    }

    public func end() async -> String {
        guard let engine = active.withLock({ $0 }) else { return "" }
        let heard = await engine.end()
        active.withLock { $0 = nil }
        return heard
    }

    public func cancel() {
        let engine = active.withLock { box -> (any DictationEngine)? in defer { box = nil }; return box }
        engine?.cancel()
    }

    public var lastReport: String { (active.withLock { $0 } ?? engine).lastReport }

    /// Whether the last dictation's microphone was all but silent.
    public var heardSilence: Bool { (active.withLock { $0 } ?? engine).loudest < 0.02 }

    /// Fetches the model for `language` ahead of the first press, so it is not a download while
    /// someone holds the keys waiting. Quiet: dictation says what went wrong when it is used.
    public static func prepare(language: String) async {
        if #available(macOS 26, *) { await ModernDictation.prepare(language: language) }
    }
}

/// `SFSpeechRecognizer`, required on-device. The fallback before macOS 26: it is years behind the
/// system's own dictation — "12245" for a spoken sentence — which is why it is only the fallback.
final class LegacyDictation: DictationEngine, @unchecked Sendable {

    /// Scoped, never held across an `await` — the same rule `ChainVoiceSession` keeps.
    private struct State {
        var engine: AVAudioEngine?
        var microphone: (any SharedMicrophone)?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var latest = ""
        var finished = false
        var buffers = 0
        var loudest: Float = 0
        var recogniserError: String?
    }

    /// What the last dictation got, for the log when it typed nothing: whether audio arrived at
    /// all, how loud it was, and what the recogniser said. "It just said listening" is otherwise
    /// three different bugs that look the same.
    var loudest: Float { state.withLock { $0.loudest } }

    public var lastReport: String {
        state.withLock { box in
            "\(box.buffers) audio buffers, loudest \(String(format: "%.3f", box.loudest))"
                + (box.recogniserError.map { ", recogniser: \($0)" } ?? "")
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts listening in `language` (a BCP 47 tag or a bare language code).
    func begin(language: String, microphone: (any SharedMicrophone)?) async throws {
        cancel()
        guard await Self.authorised() else {
            throw VoiceError.notConfigured("Dictation needs Speech Recognition, in System Settings → Privacy & Security.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw VoiceError.notConfigured("Speech recognition is not available for \(language) right now.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.notConfigured(
                "This Mac cannot recognise \(recognizer.locale.identifier) on-device, and dictation does not send your voice anywhere.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        state.withLock { $0.buffers = 0; $0.loudest = 0; $0.recogniserError = nil }
        let hear: @Sendable (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            request.append(buffer)
            let peak = SharedFrames.peak(buffer)
            self?.state.withLock { $0.buffers += 1; $0.loudest = max($0.loudest, peak) }
        }
        var engine: AVAudioEngine?
        if let microphone {
            try await microphone.startSharing { data in if let buffer = SharedFrames.buffer(data) { hear(buffer) } }
        } else {
            let own = AVAudioEngine()
            let input = own.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.audio("no microphone input available")
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in hear(buffer) }
            own.prepare()
            try own.start()
            engine = own
        }

        state.withLock { $0.latest = ""; $0.finished = false }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.state.withLock { box in
                if let result { box.latest = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { box.finished = true }
                if let error { box.recogniserError = error.localizedDescription }
            }
        }
        state.withLock { box in
            box.engine = engine
            box.microphone = microphone
            box.request = request
            box.task = task
        }
    }

    /// Stops listening and returns what was heard, waiting briefly for the recogniser to finish
    /// the last words. Empty when nothing was.
    public func end() async -> String {
        let (engine, microphone, request) = state.withLock { ($0.engine, $0.microphone, $0.request) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        microphone?.stopSharing()
        request?.endAudio()
        for _ in 0..<30 {
            if state.withLock({ $0.finished }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let heard = state.withLock { $0.latest }.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        return heard
    }

    /// Drops whatever is being heard, without typing it.
    func cancel() {
        let (engine, microphone, task) = state.withLock { box -> (AVAudioEngine?, (any SharedMicrophone)?, SFSpeechRecognitionTask?) in
            defer { box.engine = nil; box.microphone = nil; box.request = nil; box.task = nil }
            return (box.engine, box.microphone, box.task)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        microphone?.stopSharing()
        task?.cancel()
    }

    static func authorised() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

/// Apple's dictation model through `SpeechAnalyzer` — the one behind the system's own dictation
/// on macOS 26, with punctuation, and far more accurate than `SFSpeechRecognizer`. On-device.
@available(macOS 26, *)
final class ModernDictation: DictationEngine, @unchecked Sendable {

    private struct State {
        var engine: AVAudioEngine?
        var microphone: (any SharedMicrophone)?
        var analyzer: SpeechAnalyzer?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var results: Task<String, Never>?
        var segments = 0
        var buffers = 0
        var loudest: Float = 0
        var error: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var loudest: Float { state.withLock { $0.loudest } }

    var lastReport: String {
        state.withLock { box in
            "\(box.buffers) audio buffers, loudest \(String(format: "%.3f", box.loudest)), "
                + "\(box.segments) results, SpeechAnalyzer"
                + (box.error.map { ", error: \($0)" } ?? "")
        }
    }

    static func transcriber(for language: String) async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw VoiceError.notConfigured("Dictation cannot listen in \(language) on this Mac.")
        }
        // `longDictation`, not `shortDictation`: the short preset is for a single phrase and
        // stopped at the first pause — a spoken sentence came back as "No" and as "Define".
        return DictationTranscriber(locale: locale, preset: .longDictation)
    }

    /// Downloads the model if the system does not have it yet. Nothing else.
    static func prepare(language: String) async {
        guard let transcriber = try? await transcriber(for: language),
              let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        try? await request.downloadAndInstall()
    }

    func begin(language: String, microphone: (any SharedMicrophone)?) async throws {
        cancel()
        guard await LegacyDictation.authorised() else {
            throw VoiceError.notConfigured("Dictation needs Speech Recognition, in System Settings → Privacy & Security.")
        }
        let transcriber = try await Self.transcriber(for: language)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.audio("dictation has no audio format it can take")
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        // Each result is a finished stretch of speech; together they are what was said.
        let results = Task<String, Never> { [weak self] in
            var text = ""
            do {
                for try await result in transcriber.results {
                    text += String(result.text.characters)
                    self?.state.withLock { $0.segments += 1 }
                }
            } catch {
                self?.state.withLock { $0.error = error.localizedDescription }
            }
            return text
        }
        try await analyzer.start(inputSequence: stream)

        state.withLock { $0.buffers = 0; $0.loudest = 0; $0.segments = 0; $0.error = nil }
        /// Converts whatever the microphone gives into the analyzer's format and hands it over.
        func feeder(from micFormat: AVAudioFormat) -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
            guard let converter = AVAudioConverter(from: micFormat, to: format) else { return nil }
            let box = ConverterBox(converter)
            return { [weak self] buffer in
                let peak = SharedFrames.peak(buffer)
                self?.state.withLock { $0.buffers += 1; $0.loudest = max($0.loudest, peak) }
                let ratio = format.sampleRate / micFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var consumed = false
                var error: NSError?
                box.converter.convert(to: converted, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                if error == nil, converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
            }
        }

        var engine: AVAudioEngine?
        do {
            if let microphone {
                guard let feed = feeder(from: SharedFrames.format) else {
                    throw VoiceError.audio("dictation cannot convert the shared microphone's audio")
                }
                try await microphone.startSharing { data in if let buffer = SharedFrames.buffer(data) { feed(buffer) } }
            } else {
                let own = AVAudioEngine()
                let input = own.inputNode
                let micFormat = input.outputFormat(forBus: 0)
                guard micFormat.sampleRate > 0, micFormat.channelCount > 0, let feed = feeder(from: micFormat) else {
                    throw VoiceError.audio("no microphone input dictation can use")
                }
                input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in feed(buffer) }
                own.prepare()
                do {
                    try own.start()
                } catch {
                    input.removeTap(onBus: 0)
                    throw error
                }
                engine = own
            }
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        state.withLock { box in
            box.engine = engine
            box.microphone = microphone
            box.analyzer = analyzer
            box.input = continuation
            box.results = results
        }
    }

    func end() async -> String {
        let (engine, microphone, analyzer, input, results) = state.withLock { box in
            defer { box.engine = nil; box.microphone = nil; box.analyzer = nil; box.input = nil; box.results = nil }
            return (box.engine, box.microphone, box.analyzer, box.input, box.results)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        microphone?.stopSharing()
        input?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            state.withLock { $0.error = error.localizedDescription }
        }
        return (await results?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        let (engine, microphone, analyzer, input, results) = state.withLock { box in
            defer { box.engine = nil; box.microphone = nil; box.analyzer = nil; box.input = nil; box.results = nil }
            return (box.engine, box.microphone, box.analyzer, box.input, box.results)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        microphone?.stopSharing()
        input?.finish()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
}

/// Types text into the app in front by pasting it, then puts the clipboard back.
public enum TextTyper {

    /// Needs Accessibility, as any app that posts keystrokes does.
    @MainActor
    public static func type(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw VoiceError.notConfigured("Typing what you said needs Accessibility, in System Settings → Privacy & Security.")
        }
        // The shortcut's own keys may still be down; command-V with control held is a different
        // command in most apps. Wait for them to lift, briefly.
        for _ in 0..<20 where !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskSecondaryFn, .maskAlternate, .maskShift, .maskCommand]).isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Long enough for the app to have read the clipboard; then it is theirs again.
        try? await Task.sleep(nanoseconds: 400_000_000)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }
}
