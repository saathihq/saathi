//
//  SarvamSpeaker.swift
//  SaathiKit
//
//  Sarvam's mouth: a line is sent to Bulbul and what comes back is played.
//
//  It exists for the same reason as `SarvamEars`. The system has no voice at all for Marathi,
//  Malayalam, Gujarati, Punjabi or Odia, and reads their script with an English one; Bulbul speaks
//  all ten of the Indian languages Saathi can be set to, and English in the same voice.
//
//  What is sent is the text of what Saathi is about to say. With Sarvam doing the thinking that
//  text was Sarvam's to begin with. With Claude, or a model on this Mac, doing it, the reply is one
//  more thing that goes to Sarvam — which is why the sentence in Setup and `saathi provider` both
//  say that what is said back goes there as well as the voice.
//

@preconcurrency import AVFoundation
import Foundation
import os
import SaathiContract

/// Plays one clip and returns when it has been heard — or when it is stopped. A protocol so that
/// no test ever makes a sound.
public protocol AudioOutput: Sendable {
    func play(_ wav: Data) async throws
    func stop()
}

/// `AVAudioPlayer`, one clip at a time.
///
/// The delegate conformance is in an extension on purpose. `AVAudioPlayerDelegate` belongs to the
/// main actor, and declared here it would make this whole class the main actor's — when `play`
/// and `stop` are called from wherever a turn happens to be running.
public final class PlayerAudioOutput: NSObject, AudioOutput, @unchecked Sendable {

    private struct State {
        var player: AVAudioPlayer?
        var waiting: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public override init() {
        super.init()
    }

    public func play(_ wav: Data) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            throw VoiceError.audio("what Sarvam sent could not be played (\(error.localizedDescription))")
        }
        player.delegate = self

        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Started under the lock, so a `stop()` from another thread finds either nothing
                // to stop or a player that is already playing — never one about to start.
                let started = state.withLock { box -> Bool in
                    box.player = player
                    box.waiting = continuation
                    return player.play()
                }
                guard started else { return finish(player) }
                // A cancellation that landed before the player was there found nothing to stop.
                if Task.isCancelled { return stop() }
                // The delegate is the signal. This is only the backstop: a callback that never
                // comes must not leave Saathi waiting to speak for ever.
                let longest = player.duration + 1
                DispatchQueue.global().asyncAfter(deadline: .now() + longest) { [weak self] in
                    self?.finish(player)
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    public func stop() {
        guard let player = state.withLock({ $0.player }) else { return }
        player.stop()
        finish(player)
    }

    /// Ends the wait for `player`, once. A late call about a clip that has already been replaced
    /// does nothing.
    fileprivate func finish(_ player: AVAudioPlayer) {
        let continuation = state.withLock { box -> CheckedContinuation<Void, Never>? in
            guard box.player === player else { return nil }
            defer {
                box.player = nil
                box.waiting = nil
            }
            return box.waiting
        }
        continuation?.resume()
    }

}

extension PlayerAudioOutput: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(player)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(player)
    }
}

public final class SarvamSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {

    /// How Sarvam is asked to speak.
    public struct Voice: Equatable, Sendable {
        /// The language in Settings, as Saathi keeps it: "ml", "hi-IN". A line is spoken in this
        /// or in English, whichever it is written in.
        public var language: String
        /// One of Bulbul's speakers.
        public var speaker: String
        public var pace: Pace?

        public init(language: String, speaker: String = SarvamClient.defaultSpeaker, pace: Pace? = nil) {
            self.language = language
            self.speaker = speaker
            self.pace = pace
        }
    }

    /// What is done with a line Bulbul could not say: the rest of the line, its tone, and why.
    public typealias Fallback = @Sendable (_ text: String, _ tone: Tone, _ reason: String) async -> Void

    private let client: SarvamClient
    private let voice: Voice
    private let output: any AudioOutput
    private let fallback: Fallback
    private struct State {
        /// Bumped by `stop()`. A line that finds it changed has been cut off and says no more.
        var generation = 0
        /// The request to Bulbul that is out, so `stop()` can drop it: a line that has been cut
        /// off is not waited for, and nor is whoever is waiting on the line.
        var request: Task<[Data], any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        client: SarvamClient,
        voice: Voice,
        output: any AudioOutput = PlayerAudioOutput(),
        fallback: @escaping Fallback = { _, _, _ in }
    ) {
        self.client = client
        self.voice = voice
        self.output = output
        self.fallback = fallback
    }

    public func speak(_ text: String, tone: Tone) async {
        let mine = state.withLock { $0.generation }
        let pieces = Self.pieces(of: text)
        for (index, piece) in pieces.enumerated() {
            guard isCurrent(mine) else { return }
            do {
                let clips = try await synthesize(piece, tone: tone, generation: mine)
                for clip in clips {
                    guard isCurrent(mine) else { return }
                    try await output.play(clip)
                }
            } catch {
                // Cut off on purpose is not a failure to speak.
                guard isCurrent(mine), !(error is CancellationError) else { return }
                await fallback(pieces[index...].joined(separator: " "), tone, error.localizedDescription)
                return
            }
        }
    }

    public func stop() {
        let request = state.withLock { state -> Task<[Data], any Error>? in
            state.generation += 1
            defer { state.request = nil }
            return state.request
        }
        request?.cancel()
        output.stop()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    /// One request to Bulbul, kept where `stop()` can reach it.
    private func synthesize(_ piece: String, tone: Tone, generation mine: Int) async throws -> [Data] {
        let client = self.client
        let voice = self.voice
        let request = Task {
            try await client.synthesize(
                piece,
                language: Self.code(for: piece, in: voice.language),
                speaker: voice.speaker,
                pace: Double(SpeechSettings.rateMultiplier(tone: tone, pace: voice.pace)))
        }
        let wanted = state.withLock { state -> Bool in
            guard state.generation == mine else { return false }
            state.request = request
            return true
        }
        guard wanted else {
            request.cancel()
            throw CancellationError()
        }
        defer { state.withLock { if $0.request == request { $0.request = nil } } }
        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    /// Sarvam's code for the language a line is written in: the one in Settings, or English for
    /// one of Saathi's own English sentences. The same choice the system voice makes, for the same
    /// reason — a Malayalam voice asked to normalise "I did not catch that" is as wrong as the
    /// reverse.
    static func code(for text: String, in language: String) -> String {
        let written = SpeechSettings.spokenLanguage(of: text, wanted: language) ?? language
        return SarvamLanguage.code(for: written) ?? SarvamLanguage.code(for: language) ?? "en-IN"
    }

    /// A long reply cut where a listener would breathe: at the ends of sentences, into pieces
    /// Bulbul will take. A reply is a sentence or two and is nearly always one piece.
    static func pieces(of text: String, limit: Int = SarvamClient.longestUtterance - 100) -> [String] {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard length(whole) > limit else { return whole.isEmpty ? [] : [whole] }

        var pieces: [String] = []
        var current = ""
        func close() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }
        whole.enumerateSubstrings(in: whole.startIndex..., options: .bySentences) { sentence, _, _, _ in
            for part in hardSplit(sentence ?? "", limit: limit) {
                if length(current) + length(part) > limit { close() }
                current += part
            }
        }
        close()
        return pieces
    }

    /// How long Bulbul will find a piece of text: in code points, which is how its limit is
    /// written. Not in letters as they appear on the page — in Malayalam or Tamil one of those is
    /// often two or three code points, and a reply that looked well inside the limit was not.
    private static func length(_ text: some StringProtocol) -> Int {
        text.unicodeScalars.count
    }

    /// A sentence too long for one request, cut at spaces — and, for a run with no spaces in it,
    /// wherever the limit falls, between letters and never through one. There is nowhere better.
    private static func hardSplit(_ sentence: String, limit: Int) -> [String] {
        guard length(sentence) > limit else { return [sentence] }
        var parts: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word) + " "
            while length(word) > limit {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                var head = ""
                for letter in word {
                    if length(head) + letter.unicodeScalars.count > limit { break }
                    head.append(letter)
                }
                // One letter longer than the whole limit cannot be cut at all; it goes as it is.
                if head.isEmpty { head = String(word.prefix(1)) }
                parts.append(head)
                word = String(word.dropFirst(head.count))
            }
            if length(current) + length(word) > limit {
                parts.append(current)
                current = ""
            }
            current += word
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
