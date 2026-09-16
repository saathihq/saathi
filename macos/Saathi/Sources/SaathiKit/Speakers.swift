//
//  Speakers.swift
//  SaathiKit
//
//  Two ways to say something, and one way to open a link.
//

import AVFoundation
import AppKit
import Foundation
import os
import SaathiContract

/// Says the line out loud with the system voice.
///
/// Tone maps to rate and pitch rather than to a different voice: switching voices mid-session is
/// disorienting, and the three tones are meant to be the same companion sounding different, not
/// three companions.
public final class SystemSpeaker: Speaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = SerialTaskQueue()

    public init() {}

    // Two overlapping calls run one after the other instead of the first being stranded, and a
    // caller's cancellation reaches the utterance it is waiting on (see `say`).
    public func speak(_ text: String, tone: Tone) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        switch tone {
        case .calm:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            utterance.pitchMultiplier = 0.95
        case .encouraging:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.08
        case .neutral:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
        }

        await queue.run { await self.say(utterance) }
    }

    // A CLI exits the moment its work is done, which would cut the sentence off — or, as it
    // turned out, before it started: `isSpeaking` stays false for ~50 ms after `speak()`, so
    // polling it returned at once and every spoken command was silent. The delegate is the
    // only signal that means what it says.
    private func say(_ utterance: AVSpeechUtterance) async {
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
