//
//  IslandModel.swift
//  SaathiShell
//
//  What the open island shows, and what its buttons do. The panel owns one of each and the shell
//  fills them in; the SwiftUI views read the model and call the actions, so the Home panel can be
//  built and checked without a voice session, a menu or a display behind it.
//

import Foundation
import SaathiContract
import SaathiKit

/// Which face of the island is showing. Two, deliberately: a panel that grows a third tab is a
/// panel that has become a settings window, which this is not.
/// The languages the Setup tab offers, and the tag each one sends.
///
/// A short list rather than every language OpenAI supports: this is a picker in a small panel, not
/// a locale browser, and the realtime model handles anything the learner actually speaks to it. The
/// point of the setting is to stop it *guessing* — it answered a Delhi user in Korean — so what
/// matters is that a definite answer can be given, and that "follow this Mac" is the default.
public struct IslandLanguage: Identifiable, Equatable, Sendable {
    public let tag: String
    public let title: String
    public var id: String { tag }

    public static let all: [IslandLanguage] = [
        IslandLanguage(tag: "", title: "Follow this Mac"),
        IslandLanguage(tag: "en", title: "English"),
        IslandLanguage(tag: "hi", title: "हिन्दी"),
        IslandLanguage(tag: "ta", title: "தமிழ்"),
        IslandLanguage(tag: "te", title: "తెలుగు"),
        IslandLanguage(tag: "bn", title: "বাংলা"),
        IslandLanguage(tag: "mr", title: "मराठी"),
        IslandLanguage(tag: "kn", title: "ಕನ್ನಡ"),
        IslandLanguage(tag: "ml", title: "മലയാളം"),
        IslandLanguage(tag: "es", title: "Español"),
        IslandLanguage(tag: "fr", title: "Français"),
        IslandLanguage(tag: "de", title: "Deutsch"),
        IslandLanguage(tag: "ja", title: "日本語"),
        IslandLanguage(tag: "ko", title: "한국어"),
        IslandLanguage(tag: "zh", title: "中文"),
    ]
}

/// Which face of the island is showing. OpenClicky's three, in its order: two pills in the band
/// and Settings behind the gear, so the visible tab bar stays Home · Agents.
/// One icon in the "Active integrations" box: what it is, how it is drawn, and whether it is
/// configured. A row of data rather than a row of hand-written views, so adding one is a line here.
public struct IslandIntegration: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name, and the colour the tile takes once it is connected.
    public let systemImage: String
    public let tintHex: String
    public var isOn: Bool

    public init(id: String, title: String, systemImage: String, tintHex: String, isOn: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tintHex = tintHex
        self.isOn = isOn
    }

    /// OpenClicky's two, with its colours: the tool bridge and the computer-use driver.
    public static let all: [IslandIntegration] = [
        IslandIntegration(id: "composio", title: "Composio", systemImage: "link", tintHex: "#7C6CFF"),
        IslandIntegration(id: "computer-use", title: "Computer Use", systemImage: "cursorarrow.rays", tintHex: "#38BDF8"),
    ]
}

public enum IslandTab: Equatable, Sendable {
    case home
    case agents
    case setup
}

/// Where one key field has got to. `saved` carries the masked form because the full key is never
/// put back into an editable field — the file is the store, not the view.
public enum KeyFieldState: Equatable, Sendable {
    case empty
    case editing
    case checking
    case checked(KeyCheck)
    case saved(masked: String)

    /// True only while a round trip is in flight, so the button can be made inert. A second click
    /// during a check starts a second request whose answer would land after the first and win.
    public var isBusy: Bool { self == .checking }

    /// A key may be saved only when a vendor has actually accepted it.
    public var isValid: Bool {
        switch self {
        case .checked(.valid), .saved: return true
        default: return false
        }
    }
}

/// Everything the Home panel says about Saathi right now.
@MainActor
public final class IslandModel: ObservableObject {
    /// What Saathi is doing: the word in the top band and the colour of the status dot.
    @Published public var state: CompanionState = .idle
    /// Where it thinks, as one line: "local · llama3.2".
    @Published public var providerTitle: String = ""
    /// What that choice means for the user's words: "stays on this machine", and so on.
    @Published public var privacyLine: String = ""
    /// Every permission, granted or not, so the panel can offer to fix the ones that are not.
    @Published public var permissions: [Permission: PermissionStatus] = [:]
    /// Whether the pointer companion is on show, for the toggle's wording.
    @Published public var companionVisible = true
    /// Which face of the island is showing.
    @Published public var tab: IslandTab = .home
    @Published public var openAIKeyState: KeyFieldState = .empty
    @Published public var anthropicKeyState: KeyFieldState = .empty
    /// The plan's one-line explanation of what it chose and what that means.
    @Published public var planExplanation: String = ""
    /// Says out loud that a stored key is not being used. Empty when every stored key is in play.
    @Published public var unusedKeyNote: String = ""
    /// The language Saathi speaks, as a BCP-47 tag. Empty means follow this Mac.
    @Published public var language: String = ""
    /// The realtime voice's name, and whether a turn is one connection or three steps. Shown on
    /// Home because they are otherwise invisible until you have already started talking.
    @Published public var voiceTitle: String = ""
    @Published public var laneTitle: String = ""

    /// The language row's wording: the resolved language named in its own script where the picker
    /// offers one, so "Follow this Mac" resolves to what it actually followed rather than staying
    /// vague about it.
    public var languageTitle: String {
        if let match = IslandLanguage.all.first(where: { !$0.tag.isEmpty && $0.tag == language }) {
            return match.title
        }
        let resolved = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        let named = IslandLanguage.all.first { $0.tag == resolved }?.title
            ?? Locale.current.localizedString(forLanguageCode: resolved)
            ?? resolved
        return "\(named) · this Mac"
    }
    /// The user's skill library, as the "Add skills" row reads it. Handed in by the shell so the
    /// panel can be built in a test without touching `~/.saathi/skills`.
    @Published public var skills: SkillLibraryStore?
    /// What the status pill in the band says, and whether it reads as connected. OpenClicky shows
    /// its backend's host here; Saathi has more than one lane, so the pill names whichever is in
    /// use — the vendor's host for your own key, the backend's for the hosted lane — and only reads
    /// red when that lane is missing the one thing it needs.
    @Published public var connectionTitle: String = "Set up backend"
    @Published public var isConnectionConfigured = false
    /// The Setup tab's Backend rows. Only the hosted lane has a backend; `usesBackend` is false on
    /// every other lane so the rows can say "not used" instead of reporting a token missing.
    @Published public var usesBackend = false
    @Published public var backendTitle: String = "not used"
    @Published public var isBackendConfigured = false
    /// The two integration icons along the bottom. Separate from `permissions` because these are
    /// things Saathi can be connected TO, not things macOS has to allow.
    @Published public var integrations: [IslandIntegration] = IslandIntegration.all
    /// Whether the pointer companion is docked into the island rather than out on the desktop.
    @Published public var isCursorDocked = false
    /// Whether Saathi is listening without being held. Only changes the Hands-free row's wording.
    @Published public var isAlwaysListening = false

    /// The last exchange, so "what did I ask and what did it say" can be answered at a glance.
    /// The whole conversation is in `conversation.log`; these are its last two lines.
    @Published public var lastYouSaid: String = ""
    @Published public var lastSaathiSaid: String = ""

    /// True once a permission has been granted that this process still cannot pick up. The island
    /// then offers to relaunch rather than leaving someone holding keys that do nothing.
    @Published public var needsRestart = false

    public init() {}

    /// A saved key, shown so two keys can be told apart and no more. Never a prefix of the secret
    /// itself: a logged or shoulder-surfed prefix is still part of a credential, and the last four
    /// characters of a vendor key are not enough to do anything with.
    public static func masked(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "sk-…" }
        return "sk-…" + String(trimmed.suffix(4))
    }
}

/// What the Home panel's buttons ask for. Plain closures: the shell points them at the same code
/// the menu runs, so there is one Talk, one Quit and one way to fix a permission.
public struct IslandActions {
    public var onTalk: () -> Void = {}
    public var onProvider: () -> Void = {}
    public var onFixPermission: (Permission) -> Void = { _ in }
    public var onToggleCompanion: () -> Void = {}
    public var onQuit: () -> Void = {}
    /// Ask the vendor whether one key works: which vendor to check, then the live text of *both*
    /// fields. The other field comes along because a verdict changes the plan, and the plan is
    /// decided by both keys at once — judging the field that did not change against an empty string
    /// is how the panel came to promise one thing and Save do another. The panel never validates
    /// anything itself.
    public var onCheckKey: (ProviderKind, String, String) -> Void = { _, _, _ in }
    /// Save both keys and reconfigure. Called only when at least one field is valid.
    public var onSaveKeys: (String, String) -> Void = { _, _ in }
    /// Change the language Saathi answers in. Empty means follow this Mac.
    public var onLanguage: (String) -> Void = { _ in }
    /// Relaunch Saathi so a permission grant this process could not pick up takes effect.
    public var onRestart: () -> Void = {}
    /// Dock the pointer companion into the island, or let it back out.
    public var onToggleCursorDock: () -> Void = {}
    /// The (i): say out loud what Saathi does. Closes the panel first, so the companion is in view.
    public var onExplain: () -> Void = {}
    /// Show `~/.saathi/shell.json` in the Finder — where an integration or a backend is configured.
    public var onRevealSettingsFile: () -> Void = {}
    /// Open `~/.saathi/conversation.log` — what was said, kept for exactly this kind of question.
    public var onOpenConversationLog: () -> Void = {}

    public init() {}
}

/// The bridge between the panel — an AppKit object that knows nothing about `@Published` — and the
/// SwiftUI tree inside it. The island's state and the numbers the band is laid out from, in one
/// observable object the root view watches.
@MainActor
final class IslandDisplay: ObservableObject {
    @Published var state: IslandState = .collapsed
    /// The hardware (or pretend) notch: what the compact strip hangs below.
    @Published var notchHeight: CGFloat = 0
    /// The band the title and the state word sit in; never shorter than a row of text.
    @Published var topBandHeight: CGFloat = 0
    /// How much room to leave in the middle of that band, so nothing hides under a real notch.
    @Published var notchGap: CGFloat = 0

    // The island's own geometry, published so SwiftUI can draw and animate the backdrop itself.
    //
    // It used to be an AppKit layer that Core Animation sprang while the SwiftUI content inside it
    // simply appeared — so the text arrived before the black had finished growing, which is what
    // made the open feel unfinished. OpenClicky puts the shape and the content in one `ZStack`
    // under one `.animation`, so they move as a single object; these are the numbers that lets
    // Saathi do the same.
    @Published var collapsedSize: CGSize = .zero
    @Published var compactSize: CGSize = .zero
    @Published var openSize: CGSize = .zero
    /// Nothing is drawn while collapsed on a display without a notch — only the handle marks the spot.
    @Published var hasHardwareNotch = false

    /// The backdrop's size for the state showing now.
    var islandSize: CGSize {
        switch state {
        case .collapsed: return collapsedSize
        case .compact: return compactSize
        case .open: return openSize
        }
    }

    var islandCornerRadius: CGFloat { state == .collapsed ? 11 : 16 }
}
