//
//  Speakers.swift
//  SaathiKit
//
//  Two ways to say something, and one way to open a link.
//

import AVFoundation
import AppKit
import Foundation
import NaturalLanguage
import os
import SaathiContract

/// A speaker whose current utterance can be cut short — quitting, mostly: the app says goodbye
/// and goes, and whatever it was in the middle of saying should not outlive the window it came
/// from. Not every speaker can do this (printing one cannot), so it is its own protocol.
public protocol StoppableSpeaker: Sendable {
    func stop()
}

/// Says the line out loud with the system voice.
///
/// Tone maps to rate and pitch rather than to a different voice: switching voices mid-session is
/// disorienting, and the three tones are meant to be the same companion sounding different, not
/// three companions.
public final class SystemSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = SerialTaskQueue()
    private let settings = OSAllocatedUnfairLock(initialState: SpeechSettings())
    /// Asked for once. The list only changes when someone downloads a voice in System Settings,
    /// and a relaunch picking that up is a fair price for not enumerating voices every sentence.
    private static let installedVoiceLanguages = AVSpeechSynthesisVoice.speechVoices().map(\.language)

    public init(settings: SpeechSettings = SpeechSettings()) {
        self.settings.withLock { $0 = settings }
    }

    /// Takes effect from the next line spoken. The language and pace are the learner's to change
    /// while Saathi is running — in Setup, or half way through first run.
    public func apply(_ settings: SpeechSettings) {
        self.settings.withLock { $0 = settings }
    }

    // Two overlapping calls run one after the other instead of the first being stranded, and a
    // caller's cancellation reaches the utterance it is waiting on (see `say`).
    public func speak(_ text: String, tone: Tone) async {
        await queue.run { await self.say(text, tone: tone) }
    }

    /// Cuts the current utterance off. The delegate's `didCancel` resumes whoever is waiting on
    /// it, so the call that was speaking returns rather than hanging. Harmless when nothing is
    /// being said.
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // A CLI exits the moment its work is done, which would cut the sentence off — or, as it
    // turned out, before it started: `isSpeaking` stays false for ~50 ms after `speak()`, so
    // polling it returned at once and every spoken command was silent. The delegate is the
    // only signal that means what it says.
    private func say(_ text: String, tone: Tone) async {
        let settings = self.settings.withLock { $0 }
        let utterance = AVSpeechUtterance(string: text)
        // A Tamil sentence read by an English synthesiser is noise. The voice follows the language
        // Saathi was told to speak, falling back only when this Mac has no voice for it.
        let language = SpeechSettings.voiceLanguage(
            wanted: SpeechSettings.spokenLanguage(of: text, wanted: settings.language),
            available: Self.installedVoiceLanguages,
            preferred: Locale.preferredLanguages)
        utterance.voice = AVSpeechSynthesisVoice(language: language)

        // Tone maps to rate and pitch rather than to a different voice: switching voices mid-session is
        // disorienting, and the three tones are meant to be the same companion sounding different, not
        // three companions.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * SpeechSettings.rateMultiplier(tone: tone, pace: settings.pace)
        utterance.pitchMultiplier = SpeechSettings.pitchMultiplier(tone: tone)

        let waiter = UtteranceWaiter()
        synthesizer.delegate = waiter
        synthesizer.speak(utterance)
        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)   // the delegate's didCancel resumes the waiter
        }
        synthesizer.delegate = nil
    }
}

/// Wraps any speaker and reports when speech starts and stops, so the companion's face can follow
/// its own voice without the speaker protocol knowing about faces. Stop is reported on every exit,
/// including cancellation.
public final class ObservedSpeaker: Speaker, @unchecked Sendable {
    private let inner: any Speaker
    private let onSpeakingChanged: @Sendable (Bool) -> Void

    public init(_ inner: any Speaker, onSpeakingChanged: @escaping @Sendable (Bool) -> Void) {
        self.inner = inner
        self.onSpeakingChanged = onSpeakingChanged
    }

    public func speak(_ text: String, tone: Tone) async {
        onSpeakingChanged(true)
        defer { onSpeakingChanged(false) }
        await inner.speak(text, tone: tone)
    }

    /// Passes a stop through to the speaker underneath if it is one that can be stopped; a
    /// recording or printing speaker has nothing to cut off.
    public func stop() {
        (inner as? StoppableSpeaker)?.stop()
    }
}

/// Turns the synthesizer's "finished" and "cancelled" delegate calls into one awaitable.
///
/// Handles both orders: `wait()` before the delegate fires (the normal case) and after (a very
/// short utterance on a fast machine), so neither can hang.
final class UtteranceWaiter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFinished = state.withLock { box -> Bool in
                if box.finished { return true }
                box.continuation = continuation
                return false
            }
            if alreadyFinished { continuation.resume() }
        }
    }

    private func finish() {
        let continuation = state.withLock { box -> CheckedContinuation<Void, Never>? in
            box.finished = true
            defer { box.continuation = nil }
            return box.continuation
        }
        continuation?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}

/// Prints the line instead of speaking it — for CI, for `--quiet`, and for anyone who would rather
/// read than listen. The companion says what it is doing either way.
public struct PrintingSpeaker: Speaker {
    private let prefix: String

    public init(prefix: String = "saathi:") {
        self.prefix = prefix
    }

    public func speak(_ text: String, tone: Tone) async {
        print("\(prefix) [\(tone.rawValue)] \(text)")
    }
}

/// Records what it was asked to say. Tests assert on this; nothing is spoken and nothing is opened.
///
/// `OSAllocatedUnfairLock` rather than `NSLock`: `speak` is async, and `NSLock.lock()` is
/// unavailable from an async context (a warning today, an error in the Swift 6 language mode)
/// because holding a lock across a suspension deadlocks. The scoped `withLock` cannot span one.
public final class RecordingSpeaker: Speaker, Sendable {
    public struct Line: Equatable, Sendable {
        public let text: String
        public let tone: Tone
    }

    private let recorded = OSAllocatedUnfairLock<[Line]>(initialState: [])

    public init() {}

    public func speak(_ text: String, tone: Tone) async {
        recorded.withLock { $0.append(Line(text: text, tone: tone)) }
    }

    public var lines: [Line] {
        recorded.withLock { $0 }
    }
}

public struct SystemUrlOpener: UrlOpener {
    public init() {}

    public func open(_ url: URL) async throws {
        NSWorkspace.shared.open(url)
    }
}

/// Records what it was asked to open, and opens nothing.
public final class RecordingUrlOpener: UrlOpener, Sendable {
    private let recorded = OSAllocatedUnfairLock<[URL]>(initialState: [])

    public init() {}

    public func open(_ url: URL) async throws {
        recorded.withLock { $0.append(url) }
    }

    public var opened: [URL] {
        recorded.withLock { $0 }
    }
}

/// What the system voice is told besides the words: which language to read them in, and how fast.
public struct SpeechSettings: Equatable, Sendable {
    /// BCP 47, as in `shell.json` ("ta", "ta-IN"). Nil means the fallback.
    public var language: String?
    public var pace: Pace?

    public init(language: String? = nil, pace: Pace? = nil) {
        self.language = language
        self.pace = pace
    }

    public init(_ configuration: SaathiConfiguration) {
        self.init(language: configuration.resolvedLanguage, pace: configuration.pace)
    }

    static let fallbackLanguage = "en-US"

    /// The region to read a bare language in when nothing better is known. Without it "en" became
    /// whichever English sorted first — Australian — and "pt" became Brazilian by the same accident.
    static let usualRegion = ["en": "en-US", "fr": "fr-FR", "es": "es-ES", "pt": "pt-PT", "zh": "zh-CN", "nl": "nl-NL", "de": "de-DE", "it": "it-IT"]

    /// The voice language to ask for: the wanted tag if this Mac has a voice for it; else a voice
    /// of the same language, choosing the region the person themselves uses (`preferred`, as in
    /// `Locale.preferredLanguages`), then the language's usual region, then any; else English.
    /// Pure, so it is tested against lists rather than against whatever this Mac has installed.
    public static func voiceLanguage(wanted: String?, available: [String], preferred: [String] = []) -> String {
        guard let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { return fallbackLanguage }
        let installed = { (tag: String) in available.first { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        if let exact = installed(wanted) { return exact }

        let code = wanted.split(separator: "-").first.map { $0.lowercased() } ?? wanted.lowercased()
        let isSameLanguage = { (tag: String) in tag.lowercased() == code || tag.lowercased().hasPrefix(code + "-") }
        if let theirs = preferred.filter(isSameLanguage).lazy.compactMap(installed).first { return theirs }
        if let usual = usualRegion[code].flatMap(installed) { return usual }
        return available.filter(isSameLanguage).sorted().first ?? fallbackLanguage
    }

    /// The language a line is actually *in*, between the one Saathi was told to speak and English.
    ///
    /// Saathi has sentences of its own that are written in English — "I did not catch that", the
    /// (i) explanation, the whole of first run — and a Tamil synthesiser reading them is the same
    /// noise as an English one reading Tamil. Rather than teach every caller to say which language
    /// its string is in, the speaker looks: only ever a choice between the wanted language and
    /// English, so a French sentence is never mistaken for Italian, and a line too short to tell
    /// ("OK") stays in the wanted language.
    public static func spokenLanguage(of text: String, wanted: String?) -> String? {
        guard let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { return wanted }
        let code = wanted.split(separator: "-").first.map { $0.lowercased() } ?? wanted.lowercased()
        guard code != "en" else { return wanted }

        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = [.english, NLLanguage(rawValue: code)]
        recogniser.processString(text)
        let guesses = recogniser.languageHypotheses(withMaximum: 2)
        let english = guesses[.english] ?? 0
        let theirs = guesses[NLLanguage(rawValue: code)] ?? 0
        return english > 0.75 && english > theirs ? "en" : wanted
    }

    /// Calm is a little slower; a learner who asked for slow gets slower again, whatever the tone.
    public static func rateMultiplier(tone: Tone, pace: Pace?) -> Float {
        let tonal: Float = tone == .calm ? 0.9 : 1.0
        return tonal * (pace == .slow ? 0.85 : 1.0)
    }

    public static func pitchMultiplier(tone: Tone) -> Float {
        switch tone {
        case .calm: return 0.95
        case .encouraging: return 1.08
        case .neutral: return 1.0
        }
    }
}
