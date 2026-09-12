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

    public init() {}

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

        synthesizer.speak(utterance)

        // A CLI exits the moment its work is done, which would cut the sentence off mid-word.
        // Polling is crude but it is honest about what it is waiting for.
        while synthesizer.isSpeaking {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
