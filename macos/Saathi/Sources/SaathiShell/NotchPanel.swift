//
//  NotchPanel.swift
//  SaathiShell
//
//  The island, drawn the way OpenClicky draws it: nothing at all at the top of the screen until
//  you reach for it. Collapsed it is exactly the notch — black hardware hiding a black panel — or,
//  on a display without one, a small handle tucked into the menu bar so there is something to aim
//  at. Take the pointer there and the island comes down with the face and the state word; while
//  Saathi is listening, thinking or speaking it opens a narrower strip on its own.
//
//  The window never resizes: it always covers the largest state, and the island is a layer laid
//  out inside it. Resizing a window that hangs over the menu bar flickers; moving a layer does not.
//

import AppKit
import Combine
import QuartzCore
import SaathiKit
import SaathiMascot
import SwiftUI

@MainActor
public final class NotchPanel: NSPanel {

    /// The busy strip.
    static let compactWidth: CGFloat = 240
    static let compactContentHeight: CGFloat = 56
    /// The island the pointer opens: OpenClicky's Home panel, sized the same.
    static let openWidth: CGFloat = 588
    /// Each face gets its own height. One shared number clipped whichever face was taller — and
    /// the Setup tab, with two labelled key fields, a verdict line each and an explanation that
    /// wraps to two lines, is a great deal taller than Home.
    static let homeContentHeight: CGFloat = 196
    static let setupContentHeight: CGFloat = 330

    static func openContentHeight(for tab: IslandTab) -> CGFloat {
        switch tab {
        case .home: return homeContentHeight
        case .setup: return setupContentHeight
        }
    }
    /// How often the pointer is checked against the island's hover rect.
    static let pollInterval: TimeInterval = 0.05

    /// Long enough for `IslandRootView.spring` to come to rest.
    ///
    /// The window shrinks only after this, so a closing island is never clipped by a window that got
    /// smaller before the content finished moving. SwiftUI does not publish a settling time for
    /// `.spring(response:dampingFraction:)`, and slightly long is the safe direction to be wrong in:
    /// too long leaves an invisible transparent window a moment longer, too short cuts the animation.
    static let springSettleDuration: TimeInterval = 0.9

    public let mascot: MascotView
    /// What the Home panel shows; the shell fills it in.
    public let model = IslandModel()
    /// What the Home panel's buttons do; the shell points them at the same code the menu runs.
    public var actions = IslandActions() {
        didSet { hosting.rootView = IslandRootView(display: display, model: model, mascot: mascot, actions: actions) }
    }
    /// Watches the tab so switching Home ⇄ Setup re-lays the island at the new face's height.
    /// Without this the island keeps whichever height it opened at and the taller face is clipped.
    private var tabObserver: AnyCancellable?
    /// Whoever had the keyboard before Setup took it, so they get it back. Following OpenClicky,
    /// which does the same around its text composer.
    private var applicationActiveBeforeSetup: NSRunningApplication?
    public private(set) var islandState: IslandState = .collapsed
    public var word: String { model.state.word }

    private let island = IslandView()
    private let display = IslandDisplay()
    private let hosting: NSHostingView<IslandRootView>
    private var geometry: NotchGeometry
    private var hover = IslandHover()
    private var poll: Timer?

    public convenience init(data: MascotData, color: MascotColor, screen: NSScreen) {
        self.init(data: data, color: color, geometry: Self.geometry(of: screen))
    }

    /// The geometry straight, so both kinds of display can be built and driven without one.
    public init(data: MascotData, color: MascotColor, geometry: NotchGeometry) {
        self.geometry = geometry
        mascot = MascotView(data: data, color: color, expression: .idle, frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        hosting = NSHostingView(rootView: IslandRootView(display: display, model: model, mascot: mascot, actions: actions))
        super.init(
            contentRect: Self.openRect(geometry),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        // Hovering is read from the global pointer, so the panel never needs the mouse itself to
        // open; `apply` still turns clicks on once the island is actually down; letting them
        // through while collapsed keeps the menu bar underneath it usable.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        hosting.wantsLayer = true
        island.addSubview(hosting)
        contentView = island

        // A tab switch changes how tall the island needs to be. Re-applying the current state is
        // enough: `rect(for:)` reads `model.tab`, so it lands on the new face's height with the
        // same spring the open used.
        tabObserver = model.$tab
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.apply(self.islandState) }
            }
        mascot.setAccessibilityElement(true)
        mascot.setAccessibilityRole(.image)

        layOutForScreen()
        setState(.idle)
    }

    /// The panel deliberately hangs over the menu bar; AppKit would otherwise push it down.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// A non-activating panel that never became key would swallow a SwiftUI button's first click
    /// as nothing more than a focus change — the same reason OpenClicky's own notch window
    /// overrides this.
    public override var canBecomeKey: Bool { true }

    public func show() {
        orderFrontRegardless()
        guard poll == nil else { return }
        // The timer fires on the main run loop, so it is already on the main actor.
        let poll = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                // Follow the pointer between displays, but only while nothing is on show.
                if self.islandState == .collapsed,
                   !self.geometry.screenFrame.contains(mouse),
                   let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
                    self.moveTo(screen: screen)
                }
                self.pollHover(mouse: mouse, now: CACurrentMediaTime())
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    public func hide() {
        poll?.invalidate()
        poll = nil
        orderOut(nil)
    }

    deinit {
        poll?.invalidate()
    }

    public func setState(_ state: CompanionState) {
        mascot.expression = state.mascotExpression
        model.state = state
        mascot.setAccessibilityLabel(state.word)
        let next = hover.setBusy(Self.isBusy(state), now: CACurrentMediaTime())
        if next != islandState { apply(next) }
    }

    /// Recompute the geometry for a display: the pointer has moved to another one, or the
    /// displays themselves have changed. The geometry is always recomputed from the screen that
    /// is passed and compared by value, so the same screen object with a new frame, safe area or
    /// menu-bar band re-lays the island, and an unchanged one costs nothing.
    public func moveTo(screen: NSScreen) {
        let next = Self.geometry(of: screen)
        guard next != geometry else { return }
        geometry = next
        layOutForScreen()
    }

    // MARK: internals, exercised by the tests

    /// The island's own view, and whether its content is on show — what the tests read to tell the
    /// two collapsed looks apart without a display of each kind to hand.
    var contents: IslandView { island }
    /// Whether the island is showing anything at all.
    ///
    /// It used to ask whether the hosting view was hidden. That stopped meaning anything when the
    /// backdrop moved into SwiftUI: the hosted tree now fills the window in every state and simply
    /// draws nothing while collapsed, so `isHidden` is always false. The question the tests are
    /// actually asking is whether the island is showing content, which is the state itself.
    var isContentVisible: Bool { islandState != .collapsed }

    /// Whether the island's black shape is drawn at all.
    ///
    /// This is the same predicate `IslandRootView` draws its backdrop from, not a second opinion —
    /// the shape moved into SwiftUI so it could spring together with the content, and a test that
    /// asserted on the old AppKit layer would now be asserting about a view that draws nothing.
    /// Collapsed on a display without a notch, Saathi puts nothing over the menu bar: there is no
    /// notch to pretend to be, and only the thin handle marks where to reach.
    var drawsIslandBackdrop: Bool { islandState != .collapsed || geometry.hasHardwareNotch }
    /// The hosting view's own frame, in the panel's local coordinates — what the tests read to
    /// check the open island is actually 512 pt wide and not just the (always-largest) window.
    var bodyRect: CGRect { toLocal(rect(for: islandState)) }

    /// The island's rect on screen in a given state. Collapsed on a display without a notch this
    /// reaches down to the handle, so the handle itself is something you can hover.
    func rect(for state: IslandState) -> CGRect {
        switch state {
        case .collapsed:
            return geometry.hasHardwareNotch ? geometry.notchRect : geometry.notchRect.union(geometry.handleRect)
        case .compact:
            return geometry.islandRect(width: Self.compactWidth, contentHeight: Self.compactContentHeight)
        case .open:
            return Self.openRect(geometry, tab: model.tab)
        }
    }

    /// One poll step: is the pointer in the island's hover rect, and has any grace run out.
    func pollHover(mouse: CGPoint, now: TimeInterval) {
        let margin = islandState == .collapsed ? NotchGeometry.hoverMarginCollapsed : NotchGeometry.hoverMarginOpen
        let zone = NotchGeometry.hoverRect(around: rect(for: islandState), margin: margin, screenFrame: geometry.screenFrame)
        hover.setHovering(zone.contains(mouse), now: now)
        let next = hover.tick(now: now)
        if next != islandState { apply(next) }
    }

    /// Takes or returns the keyboard, and only for the Setup tab.
    ///
    /// Saathi is an accessory app and the island is a `.nonactivatingPanel`, so while another app is
    /// frontmost it is that app — not Saathi — that receives ⌘V. Every key equivalent typed at the
    /// Setup tab went to whatever was behind it. Activating is therefore not optional if a key is
    /// ever to be pasted rather than typed by hand.
    ///
    /// Only for Setup, deliberately. Home is something you glance at on the way past; stealing the
    /// keyboard to show someone a status panel would be obnoxious, and OpenClicky draws the line in
    /// the same place — it activates for its composer and nothing else.
    func setKeyboardFocus(_ wanted: Bool) {
        if wanted {
            guard !NSApp.isActive else { makeKeyAndOrderFront(nil); return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                applicationActiveBeforeSetup = front
            }
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        } else {
            guard let previous = applicationActiveBeforeSetup else { return }
            applicationActiveBeforeSetup = nil
            // Giving the keyboard back matters more than taking it: someone who opened Setup from
            // the middle of writing something should land back in what they were writing.
            resignKey()
            previous.activate()
        }
    }

    /// Put the island layer where the state says, and show or hide what belongs to that state.
    ///
    /// The hosted SwiftUI tree switches on `display.state`: collapsed draws nothing, so the
    /// `MascotHostView` inside the compact and open cases is not in the tree at all — that is what
    /// takes the shared `MascotView` out of the window and stops its display-link ticker, the same
    /// discipline the hand-laid island used to get by calling `removeFromSuperview()` itself.
    /// `layoutSubtreeIfNeeded()` forces that SwiftUI diff to run now rather than on the next real
    /// display pass, so the change is visible to the caller (and to the tests) immediately.
    /// Set false by the tests, which need the settled state now rather than after a spring.
    var animatesIsland = true

    func apply(_ islandState: IslandState) {
        if animatesIsland {
            withAnimation(IslandRootView.spring) { applyNow(islandState) }
        } else {
            applyNow(islandState)
        }
    }

    private func applyNow(_ islandState: IslandState) {
        self.islandState = islandState
        let collapsed = islandState == .collapsed

        // Everything the SwiftUI tree needs to draw the island itself. The backdrop is no longer an
        // AppKit layer being sprung by Core Animation — SwiftUI owns the shape now, so it and the
        // content move under one animation instead of racing each other.
        display.notchHeight = geometry.notchHeight
        display.topBandHeight = geometry.topBandHeight
        display.notchGap = geometry.hasHardwareNotch ? geometry.notchWidth : 0
        display.hasHardwareNotch = geometry.hasHardwareNotch
        display.collapsedSize = rect(for: .collapsed).size
        display.compactSize = rect(for: .compact).size
        display.openSize = rect(for: .open).size
        display.state = islandState

        // The window has to be big enough BEFORE the spring runs, or the island is clipped by its
        // own window on the way out; on the way back it shrinks only once the spring has settled.
        let target = rect(for: islandState)
        let windowTarget = rect(for: .open).union(target)
        resizeWindow(to: windowTarget, growing: windowTarget.height >= frame.height)

        island.setContentFrame(toLocal(windowTarget))
        // The hosted tree fills the window and draws the island top-aligned inside it, so SwiftUI
        // can spring the shape and the content together without the window clipping either.
        hosting.frame = toLocal(windowTarget)
        island.setHandleVisible(collapsed && geometry.showsHandle)
        ignoresMouseEvents = collapsed
        setKeyboardFocus(islandState == .open && model.tab == .setup)
        contentView?.layoutSubtreeIfNeeded()
    }

    static func isBusy(_ state: CompanionState) -> Bool {
        switch state {
        // Powering down counts: the goodbye is the last thing the island has to show, and the
        // app is gone a second and a half later.
        case .listening, .thinking, .speaking, .alert, .showingStep, .celebrating, .poweringDown:
            return true
        case .asleep, .idle:
            return false
        }
    }

    // MARK: layout

    private static func geometry(of screen: NSScreen) -> NotchGeometry {
        NotchGeometry.forScreen(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliary: screen.auxiliaryTopLeftArea,
            rightAuxiliary: screen.auxiliaryTopRightArea
        )
    }

    private func layOutForScreen() {
        setFrame(Self.openRect(geometry), display: true)
        island.frame = NSRect(origin: .zero, size: frame.size)
        island.setHandleRect(toLocal(geometry.handleRect))
        apply(islandState)
    }

    /// The open island: 512 wide, and tall enough that its body always extends `topBandHeight +
    /// openContentHeight` from the top of the screen — on a hardware notch that is exactly
    /// `notchHeight + openContentHeight`, as before; where the (real or virtual) notch is shorter
    /// than a comfortable top band, the extra height is folded into the content rect so
    /// `NotchGeometry.islandRect`'s own `notchHeight + contentHeight` still lands on the same total.
    private static func openRect(_ geometry: NotchGeometry, tab: IslandTab = .home) -> CGRect {
        geometry.islandRect(
            width: openWidth,
            contentHeight: openContentHeight(for: tab) + (geometry.topBandHeight - geometry.notchHeight))
    }

    /// The window has to be at least as big as the island it will hold, or the island is clipped by
    /// its own window. Growing it *before* the spring runs and shrinking it *after* is the trick
    /// OpenClicky uses; doing it the other way round clips the content mid-animation, which is
    /// exactly what the fixed-height window did on the Setup tab.
    private func resizeWindow(to target: CGRect, growing: Bool) {
        guard frame != target else { return }
        if growing {
            setFrame(target, display: true)
        } else {
            let settle = Self.springSettleDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, self.frame != target else { return }
                self.setFrame(target, display: true)
            }
        }
    }

    /// Screen coordinates into the panel's own.
    private func toLocal(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}

/// The island's black body and, on a display without a notch, the handle that marks it. Both are
/// subviews rather than hand-added sublayers: AppKit re-sorts a backing layer's sublayers against
/// its subviews' layers on every layout pass, and a body that sorted above the mascot would leave
/// the open island a featureless black box. Subviews have a z-order AppKit guarantees, and these
/// two go in first, so whatever the panel adds afterwards is drawn over them.
@MainActor
final class IslandView: NSView {

    private let body = NSView()
    private let handle = NSView()
    private let handleLine = NSView()

    /// For the tests: which of the two collapsed looks is on show.
    var isBodyVisible: Bool { !body.isHidden }
    var isHandleVisible: Bool { !handle.isHidden }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // Transparent. The island's black shape is drawn by SwiftUI, inside the same `ZStack` as the
        // content and under the same spring, which is the whole point: an AppKit layer sprung by
        // Core Animation cannot carry the content with it, so the text landed before the black did.
        body.wantsLayer = true

        handle.wantsLayer = true
        handle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        handle.layer?.cornerRadius = NotchGeometry.handleSize.height / 2
        handleLine.wantsLayer = true
        handleLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        handleLine.layer?.cornerRadius = 1
        handle.addSubview(handleLine)
        handle.isHidden = true

        addSubview(body)
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The island's backdrop is drawn by SwiftUI now, so this only places the hosted tree. It used
    /// to fill a layer black and spring its bounds, which is precisely what made the content arrive
    /// ahead of the black: Core Animation moved the rectangle, SwiftUI knew nothing about it, and
    /// the text inside simply snapped to where it was going.
    func setContentFrame(_ rect: CGRect) {
        body.frame = rect
        body.isHidden = false
    }

    func setHandleRect(_ rect: CGRect) {
        handle.frame = rect
        handleLine.frame = CGRect(x: (rect.width - 36) / 2, y: (rect.height - 2) / 2, width: 36, height: 2)
    }

    func setHandleVisible(_ visible: Bool) {
        handle.isHidden = !visible
    }


}
