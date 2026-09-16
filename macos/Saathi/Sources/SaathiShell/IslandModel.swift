//
//  IslandModel.swift
//  SaathiShell
//
//  What the open island shows, and what its buttons do. The panel owns one of each and the shell
//  fills them in; the SwiftUI views read the model and call the actions, so the Home panel can be
//  built and checked without a voice session, a menu or a display behind it.
//

import Foundation
import SaathiKit

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

    public init() {}
}

/// What the Home panel's buttons ask for. Plain closures: the shell points them at the same code
/// the menu runs, so there is one Talk, one Quit and one way to fix a permission.
public struct IslandActions {
    public var onTalk: () -> Void = {}
    public var onProvider: () -> Void = {}
    public var onFixPermission: (Permission) -> Void = { _ in }
    public var onToggleCompanion: () -> Void = {}
    public var onQuit: () -> Void = {}

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
