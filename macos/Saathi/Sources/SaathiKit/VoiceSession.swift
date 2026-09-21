//
//  VoiceSession.swift
//  SaathiKit
//
//  One way in for "talk to Saathi", two implementations behind it.
//
//  The lane is not a preference — it is read off the provider row in the contract, because it
//  describes what the provider can actually do. OpenAI has a duplex realtime socket; Ollama does
//  not, Anthropic has no audio API at all, and Sarvam has excellent Indic speech models with no
//  socket joining them. Pretending otherwise would mean a setting that silently does nothing.
//
//  Both lanes end at the same place: a `SaathiAction` from the closed contract set, handed to the
//  same `ActionPerformer` the CLI already uses. That is the join that keeps a voice turn and a
//  typed command from being two different products.
//

import Foundation
import SaathiContract

/// What a voice turn produces as it happens. All of it is optional to observe — the CLI prints
/// transcripts, a menu-bar shell would draw them, and the tests assert on them.
public struct VoiceSessionCallbacks: Sendable {
    public var onUserTranscript: (@Sendable (String) -> Void)?
    public var onSaathiTranscript: (@Sendable (String) -> Void)?
    /// An action the model asked for, already parsed and validated against the contract.
    public var onAction: (@Sendable (SaathiAction) -> Void)?
    /// Free-text lane progress ("listening…", "thinking…"), for a status line.
    public var onStatus: (@Sendable (String) -> Void)?
    /// A screen look finished: what the model asked the eyes, and what they answered — or why they
    /// could not look. The answer goes back to the model either way; this is so it can be kept.
    public var onScreenLook: (@Sendable (_ question: String, _ answer: String) -> Void)?

    public init(
        onUserTranscript: (@Sendable (String) -> Void)? = nil,
        onSaathiTranscript: (@Sendable (String) -> Void)? = nil,
        onAction: (@Sendable (SaathiAction) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil,
        onScreenLook: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.onUserTranscript = onUserTranscript
        self.onSaathiTranscript = onSaathiTranscript
        self.onAction = onAction
        self.onStatus = onStatus
        self.onScreenLook = onScreenLook
    }
}

public protocol VoiceSession: AnyObject, Sendable {
    /// Which lane this is, so a caller can say so without re-deriving it.
    var lane: VoiceLane { get }
    /// Whether the session's own audio is Saathi's voice. True on the realtime lane, where the
    /// model speaks; false on the chain lane, which has no voice but the system's. A shell reads
    /// this to know whether a `say` or a `show_step` still needs saying out loud — reading one out
    /// over a session that speaks for itself is how one question got two answers in two voices.
    var speaksForItself: Bool { get }
    /// Open whatever the lane needs — a socket, a recogniser — and start listening.
    func start(callbacks: VoiceSessionCallbacks) async throws
    /// The learner is talking. In the realtime lane this opens the microphone; in the chain lane it
    /// starts a recognition request.
    func beginTurn() async throws
    /// The learner stopped. Commit and get an answer.
    func endTurn() async throws
    func stop() async
}

/// Builds the session the configuration calls for. The only place that maps a lane to a class.
public enum VoiceSessionFactory {

    /// Throws rather than falling back. A companion that quietly switched from an on-device model
    /// to a cloud one because the local lane was unavailable would be breaking the one promise the
    /// provider report makes, so "no silent fallback" is enforced here, not just documented.
    public static func make(
        configuration: SaathiConfiguration,
        speaker: any Speaker,
        engine: VoiceAudioEngine = VoiceAudioEngine()
    ) throws -> any VoiceSession {
        let row = configuration.providerRow

        if row.requiresKey, configuration.credential(for: row.kind) == nil {
            throw VoiceError.notConfigured(
                "\(row.kind.rawValue) needs your own API key in ~/.saathi/shell.json before it can be spoken to.")
        }
        if row.requiresToken, (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw VoiceError.notConfigured(
                "hosted mode needs an account token in ~/.saathi/shell.json before it can be spoken to.")
        }

        switch row.voice {
        case .realtime:
            return RealtimeVoiceSession(configuration: configuration, engine: engine)
        case .chain:
            return ChainVoiceSession(configuration: configuration, speaker: speaker)
        }
    }
}

// MARK: - Parsing a tool call into a contract action

/// Turns a model's function call into a `SaathiAction`, or explains why it will not.
///
/// Shared by both lanes on purpose: the realtime socket and the chain lane's chat completion
/// deliver tool calls in different envelopes but the same shape inside, and the validation that
/// matters — is this a known action, are its enums in range, is that URL really http(s) — must not
/// be written twice and drift.
public enum VoiceToolCall {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownAction(String)
        case missingParameter(action: String, parameter: String)
        case valueOutOfSet(action: String, parameter: String, value: String)

        public var description: String {
            switch self {
            case let .unknownAction(name):
                return "\(name) is not an action Saathi has"
            case let .missingParameter(action, parameter):
                return "\(action) needs \(parameter)"
            case let .valueOutOfSet(action, parameter, value):
                return "\(action) got \(parameter)=\"\(value)\", which is not one of the allowed values"
            }
        }
    }

    public static func parse(name: String, arguments: [String: Any]) -> Result<SaathiAction, Failure> {
        func string(_ key: String) -> String? {
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func int(_ key: String) -> Int? {
            if let value = arguments[key] as? Int { return value }
            if let value = arguments[key] as? Double { return Int(value) }
            if let value = string(key) { return Int(value) }
            return nil
        }

        switch name {
        case SayAction.wireName:
            guard let text = string("text"), !text.isEmpty else {
                return .failure(.missingParameter(action: name, parameter: "text"))
            }
            // An unrecognised tone is the mishearing case the closed enum exists for: fall back to
            // the schema default rather than refusing the whole line, because the WORDS are still
            // right and saying them neutrally is better than saying nothing.
            let tone = string("tone").flatMap(Tone.init(rawValue:)) ?? .neutral
            return .success(.say(SayAction(text: text, tone: tone)))

        case ShowStepAction.wireName:
            guard let title = string("title"), !title.isEmpty else {
                return .failure(.missingParameter(action: name, parameter: "title"))
            }
            guard let index = int("index") else {
                return .failure(.missingParameter(action: name, parameter: "index"))
            }
            guard let total = int("total") else {
                return .failure(.missingParameter(action: name, parameter: "total"))
            }
            let detail = string("detail").flatMap { $0.isEmpty ? nil : $0 }
            let pace = string("pace").flatMap(Pace.init(rawValue:)) ?? .normal
            return .success(.showStep(ShowStepAction(
                title: title, index: index, total: total, detail: detail, pace: pace)))

        case OpenUrlAction.wireName:
            guard let url = string("url"), !url.isEmpty else {
                return .failure(.missingParameter(action: name, parameter: "url"))
            }
            // Scheme checking lives in ActionPerformer and is not duplicated here — this is the
            // parse step, and an http(s)-only rule written twice is a rule that will disagree
            // with itself eventually.
            return .success(.openUrl(OpenUrlAction(url: url)))

        default:
            return .failure(.unknownAction(name))
        }
    }

    /// The tool list to hand a model: the generated contract bytes, parsed once.
    public static func toolDefinitions() throws -> [[String: Any]] {
        guard let data = SaathiTools.json.data(using: .utf8),
              let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw VoiceError.notConfigured("the generated tool schema is not valid JSON — regenerate the contract")
        }
        return tools
    }
}
