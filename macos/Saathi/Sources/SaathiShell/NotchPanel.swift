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
    static let openWidth: CGFloat = 512
    static let openContentHeight: CGFloat = 200
    /// How often the pointer is checked against the island's hover rect.
    static let pollInterval: TimeInterval = 0.05

    public let mascot: MascotView
    /// What the Home panel shows; the shell fills it in.
    public let model = IslandModel()
    /// What the Home panel's buttons do; the shell points them at the same code the menu runs.
    public var actions = IslandActions() {
        didSet { hosting.rootView = IslandRootView(display: display, model: model, mascot: mascot, actions: actions) }
    }
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
    var isContentVisible: Bool { !hosting.isHidden }
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
            return Self.openRect(geometry)
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

    /// Put the island layer where the state says, and show or hide what belongs to that state.
    ///
    /// The hosted SwiftUI tree switches on `display.state`: collapsed draws nothing, so the
    /// `MascotHostView` inside the compact and open cases is not in the tree at all — that is what
    /// takes the shared `MascotView` out of the window and stops its display-link ticker, the same
    /// discipline the hand-laid island used to get by calling `removeFromSuperview()` itself.
    /// `layoutSubtreeIfNeeded()` forces that SwiftUI diff to run now rather than on the next real
    /// display pass, so the change is visible to the caller (and to the tests) immediately.
    func apply(_ islandState: IslandState) {
        self.islandState = islandState
        let collapsed = islandState == .collapsed
        let bodyRect = toLocal(rect(for: islandState))
        island.setIsland(
            bodyRect,
            cornerRadius: collapsed ? 11 : 16,
            visible: !collapsed || geometry.hasHardwareNotch
        )
        island.setHandleVisible(collapsed && geometry.showsHandle)
        display.notchHeight = geometry.notchHeight
        display.topBandHeight = geometry.topBandHeight
        display.notchGap = geometry.hasHardwareNotch ? geometry.notchWidth : 0
        display.state = islandState
        hosting.frame = bodyRect
        hosting.isHidden = collapsed
        mascot.isHidden = collapsed
        ignoresMouseEvents = collapsed
        hosting.layoutSubtreeIfNeeded()
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
    private static func openRect(_ geometry: NotchGeometry) -> CGRect {
        geometry.islandRect(width: openWidth, contentHeight: openContentHeight + (geometry.topBandHeight - geometry.notchHeight))
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

        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.black.cgColor
        // Bottom corners only: the top edge is flush with the screen and never shows a curve.
        body.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        body.layer?.cornerRadius = 11

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

    /// The open and close: a quarter of a second, easing out, which is long enough to read as the
    /// island coming down and short enough not to lag the pointer that asked for it. The frame is
    /// written straight through — a backing layer runs no implicit animations, so the move is
    /// added explicitly and the settled value is the one anything reading the view sees.
    func setIsland(_ rect: CGRect, cornerRadius: CGFloat, visible: Bool) {
        body.isHidden = !visible
        guard let layer = body.layer else {
            body.frame = rect
            return
        }
        let wasBounds = layer.bounds
        let wasPosition = layer.position
        let wasCornerRadius = layer.cornerRadius
        body.frame = rect
        layer.cornerRadius = cornerRadius
        guard visible, wasBounds.size != layer.bounds.size || wasPosition != layer.position else { return }
        Self.animate(layer, key: "islandBounds", path: "bounds", from: NSValue(rect: wasBounds), to: NSValue(rect: layer.bounds))
        Self.animate(layer, key: "islandPosition", path: "position", from: NSValue(point: wasPosition), to: NSValue(point: layer.position))
        Self.animate(layer, key: "islandCorner", path: "cornerRadius", from: wasCornerRadius, to: cornerRadius)
    }

    func setHandleRect(_ rect: CGRect) {
        handle.frame = rect
        handleLine.frame = CGRect(x: (rect.width - 36) / 2, y: (rect.height - 2) / 2, width: 36, height: 2)
    }

    func setHandleVisible(_ visible: Bool) {
        handle.isHidden = !visible
    }

    private static func animate(_ layer: CALayer, key: String, path: String, from: Any, to: Any) {
        let move = CABasicAnimation(keyPath: path)
        move.fromValue = from
        move.toValue = to
        move.duration = 0.25
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: key)
    }
}
