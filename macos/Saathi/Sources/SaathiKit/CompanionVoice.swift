//
//  CompanionVoice.swift
//  SaathiKit
//
//  The one voice Saathi speaks with: this Mac's, or Sarvam's when the configuration asks for it.
//
//  Everything that says something out loud — a reply on the chain lane, a `say`, a step's
//  narration, the (i) on the island, first run — goes through one `Speaker`. It used to be the
//  system voice and nothing else. Now it is whichever voice the configuration calls for, chosen in
//  one place, so a Malayalam reply and the "I did not catch that" after it are the same speaker
//  rather than two.
//

import Foundation
import os
import SaathiContract

/// The voice this Mac has: it can be cut off, and told which language to read in and how fast.
public protocol DeviceVoice: Speaker, StoppableSpeaker {
    func apply(_ settings: SpeechSettings)
}

extension SystemSpeaker: DeviceVoice {}

/// What a configuration says about Sarvam's ears and mouth. The one place that reads it.
public enum SarvamSpeech {

    /// Whether a turn is heard and spoken by Sarvam. Only ever on the chain lane: the realtime
    /// lane carries its own speech over its own connection and does not read `speech` at all.
    public static func isOn(_ configuration: SaathiConfiguration) -> Bool {
        configuration.providerRow.voice == .chain && configuration.resolvedSpeech == .sarvam
    }

    public struct Settings: Equatable, Sendable {
        public let key: String
        /// Sarvam's code for the language in Settings: "ml-IN".
        public let language: String
        public let speaker: String
    }

    /// What Sarvam's speech needs from this configuration, or why it cannot be used.
    ///
    /// A reason, never a way round. A language Sarvam does not speak is not quietly listened to on
    /// this Mac instead: that would be the voice going somewhere other than where the report says.
    public static func settings(for configuration: SaathiConfiguration) throws -> Settings {
        guard let key = configuration.credential(for: .sarvam) else {
            throw VoiceError.notConfigured("Sarvam's speech needs a Sarvam key. Add one in Setup.")
        }
        let tag = configuration.resolvedLanguage
        guard let language = SarvamLanguage.code(for: tag) else {
            throw VoiceError.notConfigured(
                "Sarvam hears and speaks ten Indian languages and English, and \(SarvamLanguage.name(of: tag)) "
                + "is not one of them. Choose another language in Setup, or another place for Saathi to think.")
        }
        return Settings(key: key, language: language, speaker: speaker(named: configuration.voice))
    }

    /// The Bulbul voice to ask for: the one named in `shell.json` when Bulbul has it, and its
    /// default otherwise. A name it does not have — a realtime voice left behind by another
    /// provider, a typo — is not sent, because it would fail every sentence.
    public static func speaker(named name: String?) -> String {
        let wanted = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return SarvamClient.speakers.contains(wanted) ? wanted : SarvamClient.defaultSpeaker
    }
}

public final class CompanionVoice: Speaker, StoppableSpeaker, @unchecked Sendable {

    private let device: any DeviceVoice
    private let makeOutput: @Sendable () -> any AudioOutput
    private let urlSession: URLSession
    private let installedVoices: [String]

    private struct State {
        var sarvam: SarvamSpeaker?
        /// Bumped by `stop()`: a line asked for before it is not said after it.
        var generation = 0
        var onFailure: (@Sendable (String) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = SerialTaskQueue()

    public init(
        configuration: SaathiConfiguration,
        device: any DeviceVoice = SystemSpeaker(),
        output: @escaping @Sendable () -> any AudioOutput = { PlayerAudioOutput() },
        urlSession: URLSession = SarvamClient.session,
        installedVoices: [String] = SystemSpeaker.installedVoiceLanguages
    ) {
        self.device = device
        self.makeOutput = output
        self.urlSession = urlSession
        self.installedVoices = installedVoices
        apply(configuration)
    }

    /// Where a failure to speak through Sarvam is reported, in a sentence. Set after the fact
    /// rather than in `init`, because whoever wants to hear about it is usually still being built.
    public func reportFailures(to handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.onFailure = handler }
    }

    /// Takes effect from the next line. `scripted` is first run: its lines are written in English
    /// and are read by this Mac's English voice, whatever has been configured.
    public func apply(_ configuration: SaathiConfiguration, scripted: Bool = false) {
        device.apply(Self.deviceSettings(for: configuration, scripted: scripted))
        let sarvam = scripted ? nil : makeSarvam(for: configuration)
        state.withLock { $0.sarvam = sarvam }
    }

    /// What this Mac's voice is told. `scripted` lines are English, so they are read by an English
    /// voice whatever language was just chosen — a Tamil synthesiser reading English sentences is
    /// the same noise as the reverse. The pace still follows at once.
    public static func deviceSettings(for configuration: SaathiConfiguration, scripted: Bool) -> SpeechSettings {
        var settings = SpeechSettings(configuration)
        if scripted { settings.language = "en-US" }
        return settings
    }

    /// Said by this Mac's voice when Sarvam could not say a line and this Mac cannot read it.
    static let couldNotSpeak = "I could not speak through Sarvam just now."

    /// Whether the next line would be Sarvam's.
    public var speaksThroughSarvam: Bool {
        state.withLock { $0.sarvam != nil }
    }

    // One line after another, whichever voice says them, and a line asked for before a stop is
    // dropped rather than said after it: holding the keys to talk over Saathi must not be answered
    // by the next thing it had queued up.
    public func speak(_ text: String, tone: Tone) async {
        let asked = state.withLock { $0.generation }
        await queue.run { [self] in
            let (sarvam, current) = state.withLock { ($0.sarvam, $0.generation) }
            guard current == asked else { return }
            if let sarvam {
                await sarvam.speak(text, tone: tone)
            } else {
                await device.speak(text, tone: tone)
            }
        }
    }

    public func stop() {
        let sarvam = state.withLock { state -> SarvamSpeaker? in
            state.generation += 1
            return state.sarvam
        }
        sarvam?.stop()
        device.stop()
    }

    private func makeSarvam(for configuration: SaathiConfiguration) -> SarvamSpeaker? {
        // A configuration Sarvam cannot speak for has already been refused where the session is
        // made, with the reason. This Mac's voice is what is left to say so with.
        guard SarvamSpeech.isOn(configuration),
              let settings = try? SarvamSpeech.settings(for: configuration) else { return nil }

        let language = configuration.resolvedLanguage
        let device = self.device
        let canRead = SpeechSettings.hasVoice(for: language, available: installedVoices)
        return SarvamSpeaker(
            client: SarvamClient(key: settings.key, urlSession: urlSession),
            voice: SarvamSpeaker.Voice(language: language, speaker: settings.speaker, pace: configuration.pace),
            output: makeOutput(),
            fallback: { [weak self] text, tone, reason in
                self?.state.withLock { $0.onFailure }?("Sarvam could not speak: \(reason)")
                // Going silent is the worse failure for someone who cannot see why. The line
                // itself, when this Mac has a voice for the language; one English sentence when it
                // does not, because an English voice reading Malayalam script is noise. The
                // sentence is true whatever the reason was; the reason is what was reported above.
                if canRead {
                    await device.speak(text, tone: tone)
                } else {
                    await device.speak(Self.couldNotSpeak, tone: .calm)
                }
            })
    }
}
