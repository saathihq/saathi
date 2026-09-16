//
//  MenuBarController.swift
//  SaathiShell
//
//  The status item and its menu. It knows nothing about voice: it shows what it is told and
//  reports clicks through closures, so the menu can be tested without a session behind it.
//

import AppKit
import SaathiKit

@MainActor
public final class MenuBarController: NSObject {

    public var onTalk: () -> Void = {}
    public var onToggleCompanion: (Bool) -> Void = { _ in }
    public var onToggleStartAtLogin: (Bool) -> Void = { _ in }
    public var onProvider: () -> Void = {}
    public var onRunOnboarding: () -> Void = {}
    public var onFixPermissions: () -> Void = {}
    public var onQuit: () -> Void = {}

    public let menu = NSMenu()
    private let statusItem: NSStatusItem?

    private let stateItem = NSMenuItem(title: CompanionState.idle.word, action: nil, keyEquivalent: "")
    private let talkItem = NSMenuItem(title: "Talk", action: #selector(talk), keyEquivalent: "")
    private let companionItem = NSMenuItem(title: "Companion", action: #selector(toggleCompanion), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let providerItem = NSMenuItem(title: "Provider…", action: #selector(provider), keyEquivalent: "")
    private let onboardingItem = NSMenuItem(title: "Run onboarding again", action: #selector(runOnboarding), keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "Fix permissions…", action: #selector(fixPermissions), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Saathi", action: #selector(quit), keyEquivalent: "q")

    /// - Parameter installStatusItem: false in tests, where there is no status bar to put it in.
    public init(icon: NSImage, installStatusItem: Bool = false) {
        statusItem = installStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) : nil
        super.init()
        statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "Saathi"
        statusItem?.menu = menu

        menu.autoenablesItems = false   // we set isEnabled ourselves; AppKit would re-enable by target/action
        stateItem.isEnabled = false
        onboardingItem.isEnabled = false   // slice 4
        companionItem.state = .on

        for item in [stateItem, NSMenuItem.separator(), talkItem, companionItem, loginItem, providerItem, onboardingItem, permissionsItem, NSMenuItem.separator(), quitItem] {
            item.target = self
            menu.addItem(item)
        }
        setPermissionsNeeded([])
    }

    public func setState(_ state: CompanionState) {
        stateItem.title = state.word
        talkItem.title = state == .listening ? "Stop talking" : "Talk"
    }

    public func setCompanionVisible(_ visible: Bool) {
        companionItem.state = visible ? .on : .off
    }

    public func setStartAtLogin(_ enabled: Bool) {
        loginItem.state = enabled ? .on : .off
    }

    /// Titles of permissions still missing; empty hides the item.
    public func setPermissionsNeeded(_ titles: [String]) {
        permissionsItem.isHidden = titles.isEmpty
        permissionsItem.title = "Fix permissions: \(titles.joined(separator: ", "))…"
    }

    @objc private func talk() { onTalk() }
    @objc private func toggleCompanion() {
        companionItem.state = companionItem.state == .on ? .off : .on
        onToggleCompanion(companionItem.state == .on)
    }
    @objc private func toggleStartAtLogin() {
        loginItem.state = loginItem.state == .on ? .off : .on
        onToggleStartAtLogin(loginItem.state == .on)
    }
    @objc private func provider() { onProvider() }
    @objc private func runOnboarding() { onRunOnboarding() }
    @objc private func fixPermissions() { onFixPermissions() }
    @objc private func quit() { onQuit() }
}
