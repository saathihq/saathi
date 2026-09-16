//
//  CompanionPanel.swift
//  SaathiShell
//
//  The buddy next to the pointer: a small transparent panel that floats above everything, on every
//  Space, and lets every click through. It trails the pointer with an easing so it reads as company
//  rather than as a second cursor. It is a redundant cue by design — the island shows the same
//  state in words, and VoiceOver reads the same word from this view.
//

import AppKit
import SaathiKit

@MainActor
public final class CompanionPanel: NSPanel {

    /// Room for the glow around the 16 pt triangle.
    public static let side: CGFloat = 48

    public let buddy: PointerBuddyView
    private var follower: PointerFollower
    private var timer: Timer?
    private var lastStep: TimeInterval = CACurrentMediaTime()
    private var lastPointer: CGPoint?

    /// How close to its place beside the pointer counts as arrived: below a quarter point the
    /// ease has nothing left to show on any display.
    static let settledDistance: CGFloat = 0.25

    /// How many times the window has actually been moved. The tests read it to tell a still
    /// buddy from one that is being re-placed sixty times a second where it already is.
    private(set) var moves = 0

    public private(set) var isShowing = false

    public init() {
        let size = NSSize(width: Self.side, height: Self.side)
        buddy = PointerBuddyView(frame: NSRect(origin: .zero, size: size))
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
        // Above submenus and popups, which is where OpenClicky's buddy lives.
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = buddy
        setState(.idle)
    }

    public func show() {
        guard !isShowing else { return }
        isShowing = true
        lastStep = CACurrentMediaTime()
        orderFrontRegardless()
        // The timer fires on the main run loop, so it is already on the main actor.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
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

    deinit {
        timer?.invalidate()
    }

    /// The buddy has no face, so the state shows in its glow: it breathes while Saathi listens and
    /// spreads while it thinks. The word itself goes to VoiceOver, which is the channel that has to
    /// carry it either way.
    public func setState(_ state: CompanionState) {
        buddy.setAccessibilityLabel(state.word)
        switch state {
        case .listening:
            buddy.glowRadius = 8
            buddy.setPulsing(true)
        case .thinking:
            buddy.glowRadius = 12
            buddy.setPulsing(false)
        default:
            buddy.glowRadius = 8
            buddy.setPulsing(false)
        }
    }

    /// One frame of following. Internal so tests can drive it without a timer.
    ///
    /// Moving a window is not free — it goes to the window server and redraws — and the buddy is
    /// asked to step sixty times a second whether or not the pointer went anywhere. So a still
    /// pointer that the ease has already caught up with costs nothing at all, and an ease whose
    /// remaining fraction of a point rounds to the origin the panel is already at is not written.
    func step(pointer: CGPoint, dt: TimeInterval) {
        if pointer == lastPointer, remainingDistance(to: pointer) < Self.settledDistance { return }
        lastPointer = pointer
        follower.follow(pointer, dt: dt)
        let origin = Self.integral(follower.origin(forPanelOf: frame.size))
        if origin == frame.origin, remainingDistance(to: pointer) < Self.settledDistance { return }
        moves += 1
        setFrameOrigin(origin)
    }

    /// How far the eased position still has to travel to the buddy's place beside the pointer.
    private func remainingDistance(to pointer: CGPoint) -> CGFloat {
        hypot(pointer.x + follower.offset.dx - follower.position.x,
              pointer.y + follower.offset.dy - follower.position.y)
    }

    /// AppKit snaps a window's frame to the backing pixel grid, which can grow `side` × `side`
    /// by a point on whichever axis the origin lands off-pixel. Rounding first keeps the panel
    /// exactly its declared size regardless of where the pointer happens to sit.
    private static func integral(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }
}
