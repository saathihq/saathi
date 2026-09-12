// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.1.0.

import Foundation

/// Where the backend lives, and how this client is configured to reach it.
public enum SaathiBackend {
    public static let defaultBaseURL = "https://api.saathi.dev"
    public static let contractVersion = "0.1.0"
}

/// `~/.saathi/shell.json`.
public struct SaathiConfiguration: Codable, Sendable {
    /// Overrides the hosted default.
    public var backendUrl: String?
    /// Bearer token for the backend.
    public var token: String?

    public init(backendUrl: String? = nil, token: String? = nil) {
        self.backendUrl = backendUrl
        self.token = token
    }

    /// The hosted backend unless the config names another one.
    public var resolvedBaseURL: String {
        let trimmed = backendUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SaathiBackend.defaultBaseURL : trimmed
    }
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

/// Every action a Saathi client can be asked to perform. Closed on purpose: a mishearing
/// can produce a wrong value inside one of these, never a command outside the set.
public enum SaathiAction: Sendable, Equatable {
    case say(SayAction)
    case showStep(ShowStepAction)
    case openUrl(OpenUrlAction)

    public var wireName: String {
        switch self {
        case .say: return SayAction.wireName
        case .showStep: return ShowStepAction.wireName
        case .openUrl: return OpenUrlAction.wireName
        }
    }

    /// The wire names, in schema order — for building a tool list or a smoke test.
    public static let allWireNames: [String] = ["say", "show_step", "open_url"]
}
