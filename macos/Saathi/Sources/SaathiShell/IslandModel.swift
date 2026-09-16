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
public enum IslandTab: Equatable, Sendable {
    case home
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
    /// Ask the vendor whether this key works. The panel never validates anything itself.
    public var onCheckKey: (ProviderKind, String) -> Void = { _, _ in }
    /// Save both keys and reconfigure. Called only when at least one field is valid.
    public var onSaveKeys: (String, String) -> Void = { _, _ in }

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
}
