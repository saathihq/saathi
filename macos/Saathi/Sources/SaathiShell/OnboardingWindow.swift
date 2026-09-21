//
//  OnboardingWindow.swift
//  SaathiShell
//
//  The window first run's card sits in: borderless, centred on the screen the pointer is on,
//  blurred dark behind the card's own tint, and able to take the keyboard — "Or type here" is a
//  real text field, and return presses the card's button.
//
//  A window rather than the island, for the reason the spec gives: the island is small, hangs
//  from the notch and closes when the pointer leaves, and someone meeting Saathi for the first time
//  should not have to keep their pointer parked at the top of the screen to be talked to.
//

import AppKit
import SaathiKit
import SaathiMascot
import SwiftUI

/// Borderless windows refuse the keyboard unless told otherwise.
private final class OnboardingKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
public final class OnboardingWindowController: NSObject {

    private let window: NSWindow
    private let mascot: MascotView
    private let coordinator: OnboardingCoordinator
    private let data: MascotData
    private var startAtLogin: Bool
    private let onStartAtLoginChanged: (Bool) -> Void
    private var observation: Any?
    /// Whatever was frontmost when the card took the keyboard, so closing can give it back.
    private var applicationActiveBefore: NSRunningApplication?

    public init(
        coordinator: OnboardingCoordinator,
        data: MascotData,
        languages: [(tag: String, name: String)],
        startAtLogin: Bool,
        onStartAtLoginChanged: @escaping (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.data = data
        self.startAtLogin = startAtLogin
        self.onStartAtLoginChanged = onStartAtLoginChanged

        let size = OnboardingStyle.cardSize
        let colour = MascotColor(paletteName: coordinator.model.colour ?? OnboardingModel.defaultColour, in: data)
            ?? MascotColor(hex: "#377FE6")
        mascot = MascotView(data: data, color: colour, expression: .idle, frame: NSRect(x: 0, y: 0, width: 96, height: 96))

        window = OnboardingKeyWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "Welcome to Saathi"

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = OnboardingStyle.cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let palette = Self.orderedPalette(data)
        let card = OnboardingCardView(
            coordinator: coordinator,
            mascot: mascot,
            palette: palette,
            languages: languages,
            startAtLogin: Binding(
                get: { [weak self] in self?.startAtLogin ?? false },
                set: { [weak self] in
                    self?.startAtLogin = $0
                    self?.onStartAtLoginChanged($0)
                }))
        let hosting = NSHostingView(rootView: card.preferredColorScheme(.dark))
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        window.contentView = blur

        // The face follows the model: the chosen colour at once, and an expression for what the
        // card is doing, so the character is a second cue for the same state and never a
        // different one.
        observation = coordinator.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncMascot() }
        }
        syncMascot()
    }

    /// `mascot.json`'s palette in a stable order: a dictionary's own order changes run to run, and
    /// ten dots that shuffle between launches look like a bug.
    static func orderedPalette(_ data: MascotData) -> [(name: String, hex: String)] {
        let preferred = ["blue", "cyan", "teal", "green", "yellow", "orange", "coral", "red", "pink", "purple"]
        let known = preferred.compactMap { name in data.palette[name].map { (name: name, hex: $0) } }
        let rest = data.palette.keys.filter { !preferred.contains($0) }.sorted()
            .map { (name: $0, hex: data.palette[$0] ?? "#377FE6") }
        return known + rest
    }

    /// The expression the card's face wears for a step.
    static func expression(for model: OnboardingModel, isSpeaking: Bool) -> MascotExpression {
        if isSpeaking { return .dictating }
        switch model.step {
        case .demo(.micCheck), .demo(.holdToTalk), .demo(.question): return .listening
        case .demo(.trialChat):
            if case .failed = model.trial { return .alerting }
            return model.trial == .asking ? .thinking : .idle
        case .finished: return .celebrate
        default: return .idle
        }
    }

    private func syncMascot() {
        let name = coordinator.model.colour ?? OnboardingModel.defaultColour
        if let colour = MascotColor(paletteName: name, in: data) { mascot.color = colour }
        let expression = Self.expression(for: coordinator.model, isSpeaking: coordinator.isSpeaking)
        if mascot.expression != expression { mascot.expression = expression }
    }

    public func show() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40))
        } else {
            window.center()
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationActiveBefore = front
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Takes the card away and gives the keyboard back. The second half matters more: someone who
    /// asked for onboarding from the middle of writing something should land back in it, the same
    /// way the island's Setup tab returns them.
    public func close() {
        window.orderOut(nil)
        applicationActiveBefore?.activate()
        applicationActiveBefore = nil
    }

    public var isVisible: Bool { window.isVisible }
}
