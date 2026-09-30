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
//  What is sent is the text of what Saathi is about to say. That already went to the provider that
//  wrote it, so this adds nothing to what leaves the machine — the ears are the half that does.
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
    /// Bumped by `stop()`. A line that finds it changed has been cut off and says no more.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

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
        let mine = generation.withLock { $0 }
        let pieces = Self.pieces(of: text)
        for (index, piece) in pieces.enumerated() {
            guard isCurrent(mine) else { return }
            do {
                let clips = try await client.synthesize(
                    piece,
                    language: Self.code(for: piece, in: voice.language),
                    speaker: voice.speaker,
                    pace: Double(SpeechSettings.rateMultiplier(tone: tone, pace: voice.pace)))
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
        generation.withLock { $0 += 1 }
        output.stop()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation.withLock { $0 == generation }
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
        guard whole.count > limit else { return whole.isEmpty ? [] : [whole] }

        var pieces: [String] = []
        var current = ""
        func close() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }
        whole.enumerateSubstrings(in: whole.startIndex..., options: .bySentences) { sentence, _, _, _ in
            for part in hardSplit(sentence ?? "", limit: limit) {
                if current.count + part.count > limit { close() }
                current += part
            }
        }
        close()
        return pieces
    }

    /// A sentence too long for one request, cut at spaces — and, for a run with no spaces in it,
    /// wherever the limit falls. There is nowhere better.
    private static func hardSplit(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var parts: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word) + " "
            while word.count > limit {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                parts.append(String(word.prefix(limit)))
                word = String(word.dropFirst(limit))
            }
            if current.count + word.count > limit {
                parts.append(current)
                current = ""
            }
            current += word
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
