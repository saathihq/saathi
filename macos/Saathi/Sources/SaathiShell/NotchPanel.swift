//
//  NotchPanel.swift
//  SaathiShell
//
//  The state in words, where HeyClicky puts it: a black panel over the notch with a lip below it
//  holding a small mascot and the state word. Without a notch it is a pill under the menu bar.
//  Expansion for onboarding steps and tips is slice 4; this slice is the collapsed strip.
//

import AppKit
import SaathiKit
import SaathiMascot

@MainActor
public final class NotchPanel: NSPanel {

    public let mascot: MascotView
    private let label = NSTextField(labelWithString: CompanionState.idle.word)
    private let collapsedFrame: NSRect

    public var word: String { label.stringValue }

    public init(data: MascotData, color: MascotColor, screen: NSScreen) {
        collapsedFrame = NotchGeometry.collapsedFrame(
            screen: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliary: screen.auxiliaryTopLeftArea,
            rightAuxiliary: screen.auxiliaryTopRightArea
        )
        let side: CGFloat = 22
        mascot = MascotView(data: data, color: color, expression: .idle, frame: NSRect(x: 0, y: 0, width: side, height: side))
        super.init(contentRect: collapsedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        contentView = content

        // Everything visible lives in the bottom lip; the notch itself hides whatever is under it.
        let lipHeight = min(NotchGeometry.lip, collapsedFrame.height)
        let lipY = (lipHeight - side) / 2
        mascot.frame = NSRect(x: 10, y: lipY, width: side, height: side)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 10 + side + 8, y: (lipHeight - 16) / 2, width: collapsedFrame.width - side - 28, height: 16)
        content.addSubview(mascot)
        content.addSubview(label)
        mascot.setAccessibilityElement(true)
        mascot.setAccessibilityRole(.image)
        setState(.idle)
    }

    public func show() {
        setFrame(collapsedFrame, display: true)
        orderFrontRegardless()
    }

    public func setState(_ state: CompanionState) {
        mascot.expression = state.mascotExpression
        label.stringValue = state.word
        mascot.setAccessibilityLabel(state.word)
    }
}
