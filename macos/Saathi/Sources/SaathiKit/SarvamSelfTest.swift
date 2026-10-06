//
//  SarvamSelfTest.swift
//  SaathiKit
//
//  `saathi sarvam`: one request to each thing Saathi asks of Sarvam, and what came back.
//
//  Everything Sarvam does for Saathi was written from its reference with no key to try it on. This
//  is the answer to "does it actually work", in four lines: is the key accepted, can Bulbul say a
//  sentence, can Saaras hear that sentence back, and does Sarvam-105B answer exactly what a turn
//  would send it — the tools and the request not to think aloud included, since a refusal of
//  either would otherwise show up as a companion that never replies.
//
//  It needs no microphone and no permission: the audio Saaras is asked to hear is the audio Bulbul
//  just made.
//

import Foundation
import SaathiContract

public struct SarvamSelfTest: Sendable {

    public struct Line: Equatable, Sendable {
        public let step: String
        public let passed: Bool
        public let detail: String

        public init(step: String, passed: Bool, detail: String) {
            self.step = step
            self.passed = passed
            self.detail = detail
        }
    }

    /// One short line in each language Bulbul speaks, to say and then to hear back. The name stays
    /// in Latin script, as Sarvam's own guidance for text-to-speech asks of brand names.
    static let greetings: [String: String] = [
        "en-IN": "Hello, I am Saathi.",
        "hi-IN": "नमस्ते, मैं Saathi हूँ।",
        "bn-IN": "নমস্কার, আমি Saathi।",
        "ta-IN": "வணக்கம், நான் Saathi.",
        "te-IN": "నమస్కారం, నేను Saathi.",
        "kn-IN": "ನಮಸ್ಕಾರ, ನಾನು Saathi.",
        "ml-IN": "നമസ്കാരം, ഞാൻ Saathi.",
        "mr-IN": "नमस्कार, मी Saathi आहे.",
        "gu-IN": "નમસ્તે, હું Saathi છું.",
        "pa-IN": "ਸਤ ਸ੍ਰੀ ਅਕਾਲ, ਮੈਂ Saathi ਹਾਂ।",
        "od-IN": "ନମସ୍କାର, ମୁଁ Saathi।",
    ]

    private let configuration: SaathiConfiguration
    private let urlSession: URLSession

    public init(configuration: SaathiConfiguration, urlSession: URLSession = SarvamClient.session) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// Runs the four steps. `onClip` is handed what Bulbul made, for anyone who wants to hear it.
    public func run(onClip: (@Sendable (Data) async -> Void)? = nil) async -> [Line] {
        guard let key = configuration.credential(for: .sarvam) else {
            return [Line(
                step: "key", passed: false,
                detail: "there is none. Paste one in Setup, or put \"sarvamKey\" in ~/.saathi/shell.json")]
        }
        switch await KeyValidator(urlSession: urlSession).check(.sarvam, key: key) {
        case .valid:
            break
        case let .rejected(why), let .unreachable(why):
            // Nothing after this can work, and three more lines saying so would bury the one that matters.
            return [Line(step: "key", passed: false, detail: why)]
        }
        var lines = [Line(step: "key", passed: true, detail: "accepted")]

        let client = SarvamClient(key: key, urlSession: urlSession)
        let language = SarvamLanguage.code(for: configuration.resolvedLanguage) ?? "en-IN"
        let speaker = SarvamSpeech.speaker(named: configuration.voice)
        let sentence = Self.greetings[language] ?? "Hello, I am Saathi."

        var spoken: Data?
        do {
            let clips = try await client.synthesize(sentence, language: language, speaker: speaker)
            spoken = clips.first
            let seconds = clips.compactMap { WaveFile.seconds(of: $0) }.reduce(0, +)
            lines.append(Line(
                step: "speech out", passed: true,
                detail: String(format: "%.1f s of audio for \"%@\" (%@, %@)", seconds, sentence, language, speaker)))
            if let onClip {
                for clip in clips { await onClip(clip) }
            }
        } catch {
            lines.append(Line(step: "speech out", passed: false, detail: error.localizedDescription))
        }

        if let spoken {
            do {
                let heard = try await client.transcribe(wav: spoken, language: language)
                lines.append(Line(
                    step: "speech in", passed: !heard.isEmpty,
                    detail: heard.isEmpty ? "Saaras heard nothing in the audio Bulbul had just made" : "heard \"\(heard)\""))
            } catch {
                lines.append(Line(step: "speech in", passed: false, detail: error.localizedDescription))
            }
        } else {
            lines.append(Line(step: "speech in", passed: false, detail: "not tried: there was no audio to hear"))
        }

        lines.append(await thinking())
        return lines
    }

    /// Exactly what a turn sends — the same request builder, so the same tools and the same
    /// `reasoning_effort` — to Sarvam itself, whatever this configuration thinks with.
    private func thinking() async -> Line {
        var asked = configuration
        if configuration.resolvedProvider != .sarvam {
            asked.provider = .sarvam
            asked.model = nil
            asked.providerBaseUrl = nil
        }
        do {
            let request = try ChainVoiceSession.completionRequest(
                configuration: asked,
                history: [["role": "user", "content": "Say hello in one short sentence."]])
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw SarvamError.refusal(status: status, body: data) }
            guard let message = ChainVoiceSession.message(in: data) else {
                throw SarvamError.unreadable("there was no message in it")
            }
            let said = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let calls = ChainVoiceSession.toolCalls(in: message).map(\.name)
            let what: String
            if !said.isEmpty {
                what = "said \"\(said)\""
            } else if !calls.isEmpty {
                what = "answered with a tool call (\(calls.joined(separator: ", ")))"
            } else {
                what = "answered with nothing at all"
            }
            return Line(step: "thinking", passed: !said.isEmpty || !calls.isEmpty, detail: "\(asked.resolvedModel) \(what)")
        } catch let error as SarvamError {
            return Line(step: "thinking", passed: false, detail: error.localizedDescription)
        } catch {
            return Line(step: "thinking", passed: false, detail: SarvamError.unreachable(error.localizedDescription).localizedDescription)
        }
    }

    /// The lines as the command prints them.
    public static func render(_ lines: [Line]) -> String {
        lines.map { line in
            let step = line.step.padding(toLength: 11, withPad: " ", startingAt: 0)
            return "  \(step) \(line.passed ? line.detail : "FAILED — \(line.detail)")"
        }.joined(separator: "\n")
    }
}
