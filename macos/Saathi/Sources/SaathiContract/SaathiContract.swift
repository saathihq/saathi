// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.6.0.

import Foundation

/// Where the backend lives, and how this client is configured to reach it.
public enum SaathiBackend {
    public static let defaultBaseURL = "https://api.saathi.dev"
    public static let contractVersion = "0.6.0"
}

/// One row per provider mode: where it runs, what it needs, and whether using it means
/// anything the learner says leaves their machine.
public struct SaathiProvider: Sendable, Equatable {
    public let kind: ProviderKind
    public let defaultBaseURL: String
    public let defaultModel: String
    /// Needs the user's own provider key, held on their machine.
    public let requiresKey: Bool
    /// Needs a Saathi account token.
    public let requiresToken: Bool
    /// False only for `local`. Worth surfacing to the user rather than burying.
    public let sendsDataOffMachine: Bool
    /// The header the credential goes in, empty when none is needed.
    public let keyHeader: String
    /// What precedes the credential in that header ("Bearer ", or empty).
    public let keyPrefix: String
    /// How this provider carries a spoken turn. A capability, not a preference — see the
    /// schema's providers comment for why only some providers have a realtime socket.
    public let voice: VoiceLane
    /// The realtime voice model, empty on every chain-lane row — see the schema's
    /// providers comment for why this is not `defaultModel`.
    public let defaultVoiceModel: String
    /// The realtime voice's name, empty where there is no socket to speak over.
    public let defaultVoice: String
    public let summary: String

    public static let all: [SaathiProvider] = [
        SaathiProvider(kind: .local, defaultBaseURL: "http://localhost:11434", defaultModel: "llama3.2", requiresKey: false, requiresToken: false, sendsDataOffMachine: false, keyHeader: "", keyPrefix: "", voice: .chain, defaultVoiceModel: "", defaultVoice: "", summary: "An OpenAI-compatible server on this machine — Ollama, LM Studio, llama.cpp. No key, no account, nothing leaves the device."),
        SaathiProvider(kind: .openai, defaultBaseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", voice: .realtime, defaultVoiceModel: "gpt-realtime", defaultVoice: "cedar", summary: "Your own OpenAI key, held on your machine and sent straight to OpenAI. Saathi's servers are not involved."),
        SaathiProvider(kind: .anthropic, defaultBaseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "x-api-key", keyPrefix: "", voice: .chain, defaultVoiceModel: "", defaultVoice: "", summary: "Your own Anthropic key, held on your machine and sent straight to Anthropic. Saathi's servers are not involved."),
        SaathiProvider(kind: .sarvam, defaultBaseURL: "https://api.sarvam.ai/v1", defaultModel: "sarvam-105b", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", voice: .chain, defaultVoiceModel: "", defaultVoice: "", summary: "Your own Sarvam AI key, sent straight to Sarvam. Indian-built models with real Indic-language coverage — the reason this option exists, given where Saathi starts."),
        SaathiProvider(kind: .hosted, defaultBaseURL: "https://api.saathi.dev", defaultModel: "", requiresKey: false, requiresToken: true, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", voice: .realtime, defaultVoiceModel: "gpt-realtime", defaultVoice: "cedar", summary: "Saathi's hosted backend holds the provider keys; you hold an account token. For people who would rather not run or configure anything."),
    ]

    /// The one header this provider needs, ready to set — or nil when it needs none.
    /// Built here so no client hard-codes `Bearer` for one provider and `x-api-key` for another.
    public func authorizationHeader(credential: String) -> (name: String, value: String)? {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyHeader.isEmpty, !trimmed.isEmpty else { return nil }
        return (keyHeader, keyPrefix + trimmed)
    }

    public static func of(_ kind: ProviderKind) -> SaathiProvider {
        // `all` covers every case of a closed enum, so this cannot be nil in practice;
        // trapping is better than inventing a fallback that would silently pick a mode.
        guard let row = all.first(where: { $0.kind == kind }) else {
            preconditionFailure("no provider row for \(kind) — the contract is out of sync")
        }
        return row
    }
}

/// The action list as JSON-Schema function tools — the exact bytes a model is shown.
/// Identical on macOS, Windows and the backend; see contract/generate.mjs for why that matters.
public enum SaathiTools {
    public static let json = #"""
[
  {
    "type": "function",
    "name": "say",
    "description": "Speak a line to the learner. The companion narrates; this is the primary action.",
    "parameters": {
      "type": "object",
      "properties": {
        "text": {
          "type": "string",
          "description": "What to say. One or two sentences."
        },
        "tone": {
          "type": "string",
          "enum": [
            "calm",
            "encouraging",
            "neutral"
          ],
          "description": "How it should sound. Defaults to \"neutral\"."
        }
      },
      "required": [
        "text"
      ]
    }
  },
  {
    "type": "function",
    "name": "show_step",
    "description": "Put one step of something being learned in front of the learner, with its place in the whole.",
    "parameters": {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "The step itself, in a few words."
        },
        "detail": {
          "type": "string",
          "description": "One sentence of elaboration, if it helps."
        },
        "index": {
          "type": "integer",
          "description": "1-based position of this step."
        },
        "total": {
          "type": "integer",
          "description": "How many steps there are, so progress is always audible."
        },
        "pace": {
          "type": "string",
          "enum": [
            "slow",
            "normal"
          ],
          "description": "How fast to move on. Defaults to \"normal\"."
        }
      },
      "required": [
        "title",
        "index",
        "total"
      ]
    }
  },
  {
    "type": "function",
    "name": "open_url",
    "description": "Open a resource in the learner's browser. http(s) only — clients MUST reject every other scheme rather than pass it to the OS.",
    "parameters": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "An absolute http or https URL."
        }
      },
      "required": [
        "url"
      ]
    }
  },
  {
    "type": "function",
    "name": "look_at_screen",
    "description": "Look at what is on the learner's screen and answer a question about it. Call this whenever they ask about something they can see — a window, a folder, an error, a button — instead of guessing or saying you cannot see. One frame of the main display is sent to a vision model; nothing is captured at any other time.",
    "parameters": {
      "type": "object",
      "properties": {
        "question": {
          "type": "string",
          "description": "What to find out about the screen, in the learner's own words where possible."
        }
      },
      "required": [
        "question"
      ]
    }
  }
]
"""#
}

/// `~/.saathi/shell.json`.
public struct SaathiConfiguration: Codable, Sendable {
    /// Which mode to run in. Unset means local — see providers.default.
    public var provider: ProviderKind?
    /// Overrides the provider's default base URL (another Ollama host, a proxy, a compatible server).
    public var providerBaseUrl: String?
    /// Overrides the provider's default model.
    public var model: String?
    /// Deprecated: use openaiKey or anthropicKey. Still read when no vendor-specific key is set, so existing configs keep working.
    public var apiKey: String?
    /// Your own OpenAI key. Used for the realtime voice lane and for thinking. Never sent to Saathi's servers.
    public var openaiKey: String?
    /// Your own Anthropic key. Stored for a lane that does not exist yet; nothing calls it today.
    public var anthropicKey: String?
    /// Overrides the realtime voice model. Distinct from model, which is what does the thinking.
    public var voiceModel: String?
    /// The realtime voice's name. Defaults to the provider row's.
    public var voice: String?
    /// The language Saathi speaks, as a BCP-47 tag ("en", "hi", "ta", "ko"). Unset means follow this machine's language rather than let the model guess.
    public var language: String?
    /// Overrides the hosted backend URL. Only used in hosted mode.
    public var backendUrl: String?
    /// Account token for the hosted backend. Only used in hosted mode.
    public var token: String?

    public init(provider: ProviderKind? = nil, providerBaseUrl: String? = nil, model: String? = nil, apiKey: String? = nil, openaiKey: String? = nil, anthropicKey: String? = nil, voiceModel: String? = nil, voice: String? = nil, language: String? = nil, backendUrl: String? = nil, token: String? = nil) {
        self.provider = provider
        self.providerBaseUrl = providerBaseUrl
        self.model = model
        self.apiKey = apiKey
        self.openaiKey = openaiKey
        self.anthropicKey = anthropicKey
        self.voiceModel = voiceModel
        self.voice = voice
        self.language = language
        self.backendUrl = backendUrl
        self.token = token
    }

    /// The mode in effect. Unset means `.local` — running against a model on this
    /// machine, with no key and no account, is the default rather than a special case.
    public var resolvedProvider: ProviderKind { provider ?? .local }

    public var providerRow: SaathiProvider { SaathiProvider.of(resolvedProvider) }

    /// The provider's base URL, or the override if one is configured.
    public var resolvedProviderBaseURL: String {
        let trimmed = providerBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? providerRow.defaultBaseURL : trimmed
    }

    public var resolvedModel: String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? providerRow.defaultModel : trimmed
    }

    /// The realtime voice model. Separate from `resolvedModel` on purpose: the socket is
    /// opened with this one, and opening it with the thinking model is rejected by the
    /// provider — which is exactly the bug this property exists to prevent.
    public var resolvedVoiceModel: String {
        let trimmed = voiceModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? providerRow.defaultVoiceModel : trimmed
    }

    public var resolvedVoice: String {
        let trimmed = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? providerRow.defaultVoice : trimmed
    }

    /// The language Saathi speaks. Unset follows this machine's own language, because a
    /// companion that guesses picks one at random — and being answered in a language you
    /// do not read is worse than being answered plainly in the wrong one you do.
    public var resolvedLanguage: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
    }

    /// The credential for a provider: its own vendor field first, then the legacy shared
    /// `apiKey`. Vendor-specific wins, so a config holding both an OpenAI and an Anthropic
    /// key is unambiguous — which is the whole reason the two fields exist. Providers that
    /// need no key of their own get nil even when keys are present.
    public func credential(for kind: ProviderKind) -> String? {
        guard SaathiProvider.of(kind).requiresKey else { return nil }
        let candidates: [String?]
        switch kind {
        case .openai: candidates = [openaiKey, apiKey]
        case .anthropic: candidates = [anthropicKey, apiKey]
        default: candidates = [apiKey]
        }
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The hosted backend unless the config names another one. Only meaningful in hosted mode.
    public var resolvedBaseURL: String {
        let trimmed = backendUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SaathiBackend.defaultBaseURL : trimmed
    }
}

/// Where the model actually runs. This is the choice that decides whether anything the learner says leaves their machine.
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case local
    case openai
    case anthropic
    case sarvam
    case hosted
}

/// How a spoken line should sound. Accessibility-first: the companion says what is happening, and how it says it is part of the message.
public enum Tone: String, Codable, CaseIterable, Sendable {
    case calm
    case encouraging
    case neutral
}

/// How fast to move through a sequence of steps. The learner sets this, not the model.
public enum Pace: String, Codable, CaseIterable, Sendable {
    case slow
    case normal
}

/// How a provider carries a spoken turn. Not a quality setting — a statement of what the provider can actually do, which is why it is a column in the provider table rather than a preference.
public enum VoiceLane: String, Codable, CaseIterable, Sendable {
    case realtime
    case chain
}

/// Speak a line to the learner. The companion narrates; this is the primary action.
public struct SayAction: Codable, Sendable, Equatable {
    public static let wireName = "say"

    /// What to say. One or two sentences.
    public var text: String
    /// How it should sound.
    public var tone: Tone

    public init(text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

/// Put one step of something being learned in front of the learner, with its place in the whole.
public struct ShowStepAction: Codable, Sendable, Equatable {
    public static let wireName = "show_step"

    /// The step itself, in a few words.
    public var title: String
    /// One sentence of elaboration, if it helps.
    public var detail: String?
    /// 1-based position of this step.
    public var index: Int
    /// How many steps there are, so progress is always audible.
    public var total: Int
    /// How fast to move on.
    public var pace: Pace

    public init(title: String, index: Int, total: Int, detail: String? = nil, pace: Pace = .normal) {
        self.title = title
        self.detail = detail
        self.index = index
        self.total = total
        self.pace = pace
    }
}

/// Open a resource in the learner's browser. http(s) only — clients MUST reject every other scheme rather than pass it to the OS.
public struct OpenUrlAction: Codable, Sendable, Equatable {
    public static let wireName = "open_url"

    /// An absolute http or https URL.
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

/// Look at what is on the learner's screen and answer a question about it. Call this whenever they ask about something they can see — a window, a folder, an error, a button — instead of guessing or saying you cannot see. One frame of the main display is sent to a vision model; nothing is captured at any other time.
public struct LookAtScreenAction: Codable, Sendable, Equatable {
    public static let wireName = "look_at_screen"

    /// What to find out about the screen, in the learner's own words where possible.
    public var question: String

    public init(question: String) {
        self.question = question
    }
}

/// Every action a Saathi client can be asked to perform. Closed on purpose: a mishearing
/// can produce a wrong value inside one of these, never a command outside the set.
public enum SaathiAction: Sendable, Equatable {
    case say(SayAction)
    case showStep(ShowStepAction)
    case openUrl(OpenUrlAction)
    case lookAtScreen(LookAtScreenAction)

    public var wireName: String {
        switch self {
        case .say: return SayAction.wireName
        case .showStep: return ShowStepAction.wireName
        case .openUrl: return OpenUrlAction.wireName
        case .lookAtScreen: return LookAtScreenAction.wireName
        }
    }

    /// The wire names, in schema order — for building a tool list or a smoke test.
    public static let allWireNames: [String] = ["say", "show_step", "open_url", "look_at_screen"]
}
