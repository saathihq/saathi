//
//  CompanionPanel.swift
//  SaathiShell
//
//  The character next to the pointer: a small transparent panel that floats above everything,
//  on every Space, and lets every click through. It trails the pointer with an easing so it
//  reads as company rather than as a cursor. It is a redundant cue by design — the notch shows
//  the same state in words, and VoiceOver reads the same word from this view.
//

import AppKit
import SaathiKit
import SaathiMascot

@MainActor
public final class CompanionPanel: NSPanel {

    public static let side: CGFloat = 72

    public let mascot: MascotView
    private var follower: PointerFollower
    private var timer: Timer?
    private var lastStep: TimeInterval = CACurrentMediaTime()

    public private(set) var isShowing = false

    public init(data: MascotData, color: MascotColor) {
        let size = NSSize(width: Self.side, height: Self.side)
        mascot = MascotView(data: data, color: color, expression: .idle, frame: NSRect(origin: .zero, size: size))
        follower = PointerFollower(start: NSEvent.mouseLocation)
        super.init(
            contentRect: NSRect(origin: Self.integral(follower.origin(forPanelOf: size)), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = mascot
        mascot.setAccessibilityElement(true)
        mascot.setAccessibilityRole(.image)
        setState(.idle)
    }

    public func show() {
        guard !isShowing else { return }
        isShowing = true
        lastStep = CACurrentMediaTime()
        orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.step(pointer: NSEvent.mouseLocation, dt: now - self.lastStep)
                self.lastStep = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func hide() {
        timer?.invalidate()
        timer = nil
        isShowing = false
        orderOut(nil)
    }

    public func setState(_ state: CompanionState) {
        mascot.expression = state.mascotExpression
        mascot.setAccessibilityLabel(state.word)
    }

    /// One frame of following. Internal so tests can drive it without a timer.
    func step(pointer: CGPoint, dt: TimeInterval) {
        follower.follow(pointer, dt: dt)
        setFrameOrigin(Self.integral(follower.origin(forPanelOf: frame.size)))
        // Look toward the pointer: convert the screen point into the (flipped) mascot view.
        let inWindow = convertPoint(fromScreen: pointer)
        mascot.lookAt(mascot.convert(inWindow, from: nil))
    }

    /// AppKit snaps a window's frame to the backing pixel grid, which can grow `side` × `side`
    /// by a point on whichever axis the origin lands off-pixel. Rounding first keeps the panel
    /// exactly its declared size regardless of where the pointer happens to sit.
    private static func integral(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }
}
