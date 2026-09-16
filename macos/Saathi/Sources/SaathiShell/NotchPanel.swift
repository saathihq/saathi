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

@MainActor
public final class NotchPanel: NSPanel {

    /// The busy strip.
    static let compactWidth: CGFloat = 240
    static let compactContentHeight: CGFloat = 56
    /// The island the pointer opens.
    static let openWidth: CGFloat = 320
    static let openContentHeight: CGFloat = 96
    /// How often the pointer is checked against the island's hover rect.
    static let pollInterval: TimeInterval = 0.05

    public let mascot: MascotView
    public private(set) var islandState: IslandState = .collapsed
    public var word: String { label.stringValue }

    private let label = NSTextField(labelWithString: CompanionState.idle.word)
    private let island = IslandView()
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
        super.init(
            contentRect: geometry.islandRect(width: Self.openWidth, contentHeight: Self.openContentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        // Hovering is read from the global pointer, so the panel never needs the mouse itself —
        // and letting clicks through keeps the menu bar underneath it usable.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        island.addSubview(mascot)
        island.addSubview(label)
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
        label.stringValue = state.word
        mascot.setAccessibilityLabel(state.word)
        let next = hover.setBusy(Self.isBusy(state), now: CACurrentMediaTime())
        if next != islandState {
            apply(next)
        } else if islandState != .collapsed {
            layOutContent()   // a longer word needs a wider label
        }
    }

    /// Recompute the geometry when the pointer moves to another display.
    public func moveTo(screen: NSScreen) {
        let next = Self.geometry(of: screen)
        guard next != geometry else { return }
        geometry = next
        layOutForScreen()
    }

    // MARK: internals, exercised by the tests

    /// The island's own view, and whether the word is on show — what the tests read to tell the
    /// two collapsed looks apart without a display of each kind to hand.
    var contents: IslandView { island }
    var isWordHidden: Bool { label.isHidden }

    /// The island's rect on screen in a given state. Collapsed on a display without a notch this
    /// reaches down to the handle, so the handle itself is something you can hover.
    func rect(for state: IslandState) -> CGRect {
        switch state {
        case .collapsed:
            return geometry.hasHardwareNotch ? geometry.notchRect : geometry.notchRect.union(geometry.handleRect)
        case .compact:
            return geometry.islandRect(width: Self.compactWidth, contentHeight: Self.compactContentHeight)
        case .open:
            return geometry.islandRect(width: Self.openWidth, contentHeight: Self.openContentHeight)
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
    func apply(_ islandState: IslandState) {
        self.islandState = islandState
        let collapsed = islandState == .collapsed
        island.setIsland(
            toLocal(rect(for: islandState)),
            cornerRadius: collapsed ? 11 : 16,
            visible: !collapsed || geometry.hasHardwareNotch
        )
        island.setHandleVisible(collapsed && !geometry.hasHardwareNotch)
        mascot.isHidden = collapsed
        label.isHidden = collapsed
        if !collapsed { layOutContent() }
    }

    static func isBusy(_ state: CompanionState) -> Bool {
        switch state {
        case .listening, .thinking, .speaking, .alert, .showingStep, .celebrating:
            return true
        case .asleep, .idle, .poweringDown:
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
        setFrame(geometry.islandRect(width: Self.openWidth, contentHeight: Self.openContentHeight), display: true)
        island.frame = NSRect(origin: .zero, size: frame.size)
        island.setHandleRect(toLocal(geometry.handleRect))
        apply(islandState)
    }

    /// The face and the word live in the band below the notch, which is the part that is actually
    /// on show; whatever is behind the notch itself cannot be seen.
    private func layOutContent() {
        let body = toLocal(rect(for: islandState))
        let content = CGRect(
            x: body.minX,
            y: body.minY,
            width: body.width,
            height: max(0, body.height - geometry.notchHeight)
        )
        let inset: CGFloat = 14
        let side: CGFloat = 44
        mascot.frame = NSRect(x: content.minX + inset, y: content.midY - side / 2, width: side, height: side)
        let textX = mascot.frame.maxX + 10
        label.frame = NSRect(x: textX, y: content.midY - 9, width: max(0, content.maxX - inset - textX), height: 18)
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
