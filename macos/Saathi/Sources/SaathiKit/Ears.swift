//
//  Ears.swift
//  SaathiKit
//
//  One held turn of speech, turned into text.
//
//  The chain lane used to do its own listening, with Apple's on-device recogniser written straight
//  into the session. That recogniser knows English well and, on the Mac this was written on, has
//  no recogniser at all for Tamil, Telugu, Bengali, Marathi, Kannada, Malayalam, Gujarati, Punjabi
//  or Odia — so a lane that exists to work with any model could only be spoken to in one language.
//  Listening is a value now: the session is handed a pair of ears and does not know whose they are.
//

import AVFoundation
import Foundation
import os
import SaathiContract
import Speech

/// What a pair of ears can show while a turn is open. Nothing is decided from either.
public struct EarsFeedback: Sendable {
    /// How loud the microphone is, 0…1, a few times a second.
    public var onLevel: (@Sendable (Float) -> Void)?
    /// What has been made out so far. Only ears that recognise as they go have anything to say.
    public var onPartial: (@Sendable (String) -> Void)?

    public init(
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.onLevel = onLevel
        self.onPartial = onPartial
    }
}

public protocol Ears: Sendable {
    /// Asks for what it needs, once, and says in a line what it will listen with. Throws, in words
    /// a person can act on, when it cannot listen at all.
    func prepare() async throws -> String
    /// The turn has opened.
    func begin(_ feedback: EarsFeedback) async throws
    /// The turn has closed: what was said, or "" when nothing was.
    func finish() async throws -> String
    /// Stop listening and keep nothing.
    func cancel()
}

/// Apple's recogniser, required on-device. The learner's voice never leaves the machine — that is
/// the promise, not an optimisation, which is why a language it cannot do on-device is left to the
/// Mac's own recogniser, out loud, and is never a quiet trip to Apple's servers.
public final class DeviceEars: Ears, @unchecked Sendable {

    private let language: String

    /// Everything touched from both the caller and the recognition callback, behind one scoped
    /// lock. `NSLock.lock()` is unavailable from an async context in the Swift 6 language mode —
    /// and rightly so, since holding a lock across a suspension point is how deadlocks are made.
    /// `withLock` cannot span an `await`, which is the property that matters.
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var audioEngine: AVAudioEngine?
        var latestTranscript = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var recognizer: SFSpeechRecognizer?

    /// `language`: the one in Settings, as a BCP 47 tag or a bare code.
    public init(language: String) {
        self.language = language
    }

    public func prepare() async throws -> String {
        // Ask once, up front, and say what is being asked for. Being surprised by a permission
        // dialog mid-sentence is exactly the kind of thing this project should not do.
        guard await Self.requestSpeechAuthorization() else {
            throw VoiceError.notConfigured(
                "Saathi needs permission to use speech recognition. Grant it in System Settings → Privacy & Security → Speech Recognition.")
        }

        // The recogniser for the language in Settings, when this Mac has one that works on-device.
        // It used to be `SFSpeechRecognizer()` and nothing else — the Mac's own language whatever
        // Settings said — so someone who chose French on an English Mac was heard as English words.
        let own = SFSpeechRecognizer()
        var recognizer = own
        var settled = false
        switch Self.choice(
            language: language,
            machine: own?.locale.identifier ?? Locale.current.identifier,
            supported: SFSpeechRecognizer.supportedLocales().map(\.identifier)
        ) {
        case .own:
            break
        case let .locale(identifier):
            if let theirs = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               theirs.isAvailable, theirs.supportsOnDeviceRecognition {
                recognizer = theirs
            } else {
                settled = true
            }
        case .none:
            settled = true
        }

        guard let recognizer, recognizer.isAvailable else {
            throw VoiceError.notConfigured("speech recognition is not available on this Mac right now")
        }
        // The on-device requirement is the promise, not an optimisation. Without it Apple may send
        // audio to its own servers, which would make the report's "your voice stays on this
        // machine" line false — so an unavailable on-device recogniser is an error, not a fallback.
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.notConfigured(
                "on-device speech recognition is not available for \(recognizer.locale.identifier). "
                + "Add the language under System Settings → Keyboard → Dictation to download it."
                + Self.sarvamHint(language))
        }
        self.recognizer = recognizer
        // The Mac's own recogniser standing in is what this lane always did, and nothing leaves
        // the machine for it. It is said, because someone speaking Malayalam to an English
        // recogniser should be told why they are misheard and who would hear them.
        return settled
            ? Self.settledFor(recognizer.locale.identifier, insteadOf: language)
            : "ready — on-device speech recognition (\(recognizer.locale.identifier))"
    }

    public func begin(_ feedback: EarsFeedback) async throws {
        guard let recognizer else { throw VoiceError.notConfigured("start() was not called") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        let onLevel = feedback.onLevel
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: format) { buffer, _ in
            request.append(buffer)
            onLevel?(InputLevel.level(of: buffer))
        }
        engine.prepare()
        try engine.start()

        state.withLock { box in
            box.request = request
            box.audioEngine = engine
            box.latestTranscript = ""
        }

        let onPartial = feedback.onPartial
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.state.withLock { $0.latestTranscript = text }
            onPartial?(text)
        }
        state.withLock { $0.recognitionTask = task }
    }

    public func finish() async throws -> String {
        let (engine, request) = state.withLock { ($0.audioEngine, $0.request) }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()

        // Recognition finishes slightly after the audio does. Poll briefly rather than racing it —
        // the alternative is dropping the last word of every turn.
        var transcript = ""
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            transcript = state.withLock { $0.latestTranscript }
            if !transcript.isEmpty { break }
        }
        forget()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        let engine = state.withLock { $0.audioEngine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        forget()
    }

    private func forget() {
        state.withLock { box in
            box.recognitionTask?.cancel()
            box.recognitionTask = nil
            box.audioEngine = nil
            box.request = nil
        }
    }

    // MARK: which recogniser

    /// Which recogniser to ask for.
    enum Choice: Equatable {
        /// The Mac's own: it speaks the language, and knows which English its owner means.
        case own
        /// One for the language in Settings, in this region.
        case locale(String)
        /// This Mac has none for that language.
        case none
    }

    /// Pure, so the rule is tested against lists rather than against whatever this Mac has.
    ///
    /// - `language`: the one in Settings, "fr" or "fr-CA".
    /// - `machine`: the locale of the Mac's own recogniser.
    /// - `supported`: every locale a recogniser exists for, as `supportedLocales()` lists them.
    static func choice(language: String, machine: String, supported: [String]) -> Choice {
        let wanted = languageCode(of: language)
        if wanted == languageCode(of: machine) { return .own }

        let spelled = { (tag: String) in tag.replacingOccurrences(of: "_", with: "-").lowercased() }
        let same = supported.filter { languageCode(of: $0) == wanted }
        if let exact = same.first(where: { spelled($0) == spelled(language) }) { return .locale(exact) }
        // A bare language gets its usual region, not whichever sorts first: "fr" is France's.
        if let usual = SpeechSettings.usualRegion[wanted],
           let match = same.first(where: { spelled($0) == spelled(usual) }) {
            return .locale(match)
        }
        return same.sorted().first.map(Choice.locale) ?? .none
    }

    private static func languageCode(of tag: String) -> String {
        Locale(identifier: tag).language.languageCode?.identifier.lowercased()
            ?? tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
            ?? tag.lowercased()
    }

    /// What is said when the Mac's own recogniser stands in for one it does not have.
    static func settledFor(_ own: String, insteadOf language: String) -> String {
        "ready — on-device speech recognition (\(own)). This Mac cannot hear "
            + "\(SarvamLanguage.name(of: language)) on its own." + sarvamHint(language)
    }

    /// The way out, when there is one: Sarvam hears ten Indian languages this Mac cannot.
    static func sarvamHint(_ language: String) -> String {
        SarvamLanguage.code(for: language) == nil
            ? ""
            : " Sarvam can hear it: add a Sarvam key, or turn its speech on, in Setup."
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
