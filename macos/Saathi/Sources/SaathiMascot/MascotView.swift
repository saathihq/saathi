//
//  MascotView.swift
//  SaathiMascot
//
//  The character on screen. Core Animation layers for the body (a gradient masked by the outline),
//  the eyes and the mouth (white shapes, clipped to the body), all inside a motion layer; one tick
//  per frame recomputes placements from FaceGeometry and MotionTransform. The view is flipped so
//  the JSON's y-down coordinates are used unchanged.
//

import AppKit
import QuartzCore

public final class MascotView: NSView {

    public let data: MascotData

    public var expression: Expression {
        didSet { if expression != oldValue { enter(expression, hard: false) } }
    }

    public var color: MascotColor {
        didSet { applyColor() }
    }

    /// How much each face's own gaze offset drifts the whole face. The demo page defaults to 0.5.
    public var lookAround: CGFloat = 0.5
    public var motionStrength: CGFloat = 1
    /// Auto-blink and cycling between an expression's faces. Off, the face holds still.
    public var animates = true

    // MARK: layers

    private let scaled = CALayer()
    private let motion = CALayer()
    private let bodyGradient = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let faceContainer = CALayer()
    private let faceClip = CAShapeLayer()
    private let face = CALayer()
    private let eyeLeft = CAShapeLayer()
    private let eyeRight = CAShapeLayer()
    private let mouth = CAShapeLayer()

    // MARK: state, internal so tests can read it

    private(set) var faceIndex = 0
    private var fromEyes: [[CGPoint]] = []
    private var toEyes: [[CGPoint]] = []
    private var fromMouth: [Double] = []
    private var toMouth: [Double] = []
    private var fromGaze: CGPoint = .zero
    private var toGaze: CGPoint = .zero
    /// 0 = fully the previous face, 1 = fully the new one.
    private var morph: CGFloat = 1
    private(set) var stateStart: TimeInterval = 0
    private var nextFaceAt: TimeInterval = .infinity
    private(set) var nextBlinkAt: TimeInterval?
    private var blinkStart: TimeInterval?
    private var spinStart: TimeInterval?
    private var pointerGaze: CGPoint = .zero
    private(set) var pointerGazeTarget: CGPoint = .zero
    private var lastNow: TimeInterval = 0
    private var ticker: Ticker?

    private let bodyOutline: CGPath

    public override var isFlipped: Bool { true }

    public init(data: MascotData, color: MascotColor, expression: Expression, frame: NSRect) {
        self.data = data
        self.color = color
        self.expression = expression
        // Decoded once at construction; a bad outline is a programming error, not a runtime case.
        self.bodyOutline = (try? SVGPath.cgPath(from: data.bodyPath)) ?? CGMutablePath()
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        applyColor()
        lastNow = CACurrentMediaTime()
        enter(expression, hard: true)
        tick(now: CACurrentMediaTime())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MascotView is built in code") }

    // MARK: public controls

    /// Point in this view's (flipped) coordinates; nil looks straight ahead.
    public func lookAt(_ point: CGPoint?) {
        guard let point else { pointerGazeTarget = .zero; return }
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        pointerGazeTarget = CGPoint(
            x: FaceGeometry.clamp((point.x - half.width) / max(half.width, 1), -1...1),
            y: FaceGeometry.clamp((point.y - half.height) / max(half.height, 1), -1...1)
        )
    }

    public func blinkNow() {
        blinkStart = lastNow
    }

    public func spin() {
        spinStart = lastNow
    }

    // MARK: lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate()
        ticker = nil
        if window != nil {
            ticker = Ticker(view: self) { [weak self] in self?.tick(now: CACurrentMediaTime()) }
        }
    }

    public override func layout() {
        super.layout()
        // Map viewBox units to points: scale to fit, keeping the aspect (the box is square).
        let k = min(bounds.width / CGFloat(data.viewBox.width), bounds.height / CGFloat(data.viewBox.height))
        var t = CATransform3DMakeScale(k, k, 1)
        t = CATransform3DTranslate(t, -CGFloat(data.viewBox.x), -CGFloat(data.viewBox.y), 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scaled.transform = t
        CATransaction.commit()
    }

    // MARK: building

    private func buildLayers() {
        guard let root = layer else { return }
        for l in [scaled, motion, bodyGradient, bodyMask, faceContainer, faceClip, face, eyeLeft, eyeRight, mouth] {
            l.anchorPoint = .zero
            l.position = .zero
            l.masksToBounds = false
            l.contentsScale = window?.backingScaleFactor ?? 2
        }
        let inner = CGFloat(data.eyeRefX) * 2   // the body's own square, 0...228.541
        let box = CGRect(x: 0, y: 0, width: inner, height: inner)
        scaled.bounds = box
        motion.bounds = box

        var bodyTransform = data.bodyTransform.affine
        let placedOutline = bodyOutline.copy(using: &bodyTransform) ?? bodyOutline

        bodyGradient.frame = box
        bodyGradient.startPoint = CGPoint(x: 1, y: 0)
        bodyGradient.endPoint = CGPoint(x: 0, y: 1)
        bodyGradient.locations = [0, 0.55, 1]
        bodyMask.frame = box
        bodyMask.path = placedOutline
        bodyGradient.mask = bodyMask

        faceContainer.frame = box
        faceClip.frame = box
        faceClip.path = placedOutline
        faceContainer.mask = faceClip

        face.bounds = box
        face.setAffineTransform(data.faceTransform.affine)
        for eye in [eyeLeft, eyeRight] {
            eye.fillColor = CGColor(gray: 1, alpha: 1)
            eye.bounds = box
        }
        mouth.fillColor = nil
        mouth.strokeColor = CGColor(gray: 1, alpha: 1)
        mouth.lineWidth = 7.5
        mouth.lineCap = .round
        mouth.bounds = box

        face.addSublayer(eyeLeft)
        face.addSublayer(eyeRight)
        face.addSublayer(mouth)
        faceContainer.addSublayer(face)
        motion.addSublayer(bodyGradient)
        motion.addSublayer(faceContainer)
        scaled.addSublayer(motion)
        root.addSublayer(scaled)
        needsLayout = true
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyGradient.colors = [
            MascotColor.cgColor(hex: color.light),
            color.cgColor,
            MascotColor.cgColor(hex: color.dark),
        ]
        CATransaction.commit()
    }

    // MARK: expressions

    private func enter(_ expression: Expression, hard: Bool) {
        let now = lastNow
        let first = data.expressions[expression.rawValue]?.first ?? 0
        setFace(first, hard: hard, now: now)
        stateStart = now
        scheduleFace(now: now)
        scheduleBlink(now: now)
    }

    private func setFace(_ index: Int, hard: Bool, now: TimeInterval) {
        let count = data.faces.count
        let wrapped = ((index % count) + count) % count
        if wrapped == faceIndex, morph >= 1, !fromEyes.isEmpty {
            stateStart = now
            return
        }
        let target = data.faces[wrapped].map { $0.map { CGPoint(x: CGFloat($0[0]), y: CGFloat($0[1])) } }
        if hard || fromEyes.isEmpty {
            fromEyes = target
            fromMouth = data.mouths[wrapped]
            fromGaze = gazePoint(wrapped)
            morph = 1
        } else {
            fromEyes = currentEyes()
            fromMouth = currentMouth()
            fromGaze = currentGaze()
            morph = 0
        }
        toEyes = target
        toMouth = data.mouths[wrapped]
        toGaze = gazePoint(wrapped)
        faceIndex = wrapped
    }

    private func gazePoint(_ index: Int) -> CGPoint {
        let g = data.gaze[index]
        return CGPoint(x: CGFloat(g[0]), y: CGFloat(g[1]))
    }

    private func scheduleFace(now: TimeInterval) {
        if let window = data.faceInterval[expression.rawValue] ?? nil, window.count == 2 {
            nextFaceAt = now + Double.random(in: window[0]...window[1]) / 1000
        } else {
            nextFaceAt = .infinity
        }
    }

    private func scheduleBlink(now: TimeInterval) {
        if let window = data.blinkInterval[expression.rawValue] ?? nil, window.count == 2 {
            nextBlinkAt = now + Double.random(in: window[0]...window[1]) / 1000
        } else {
            nextBlinkAt = nil
        }
    }

    // MARK: interpolation

    private func currentEyes() -> [[CGPoint]] {
        zip(fromEyes, toEyes).map { from, to in
            zip(from, to).map { a, b in CGPoint(x: a.x + (b.x - a.x) * morph, y: a.y + (b.y - a.y) * morph) }
        }
    }

    private func currentMouth() -> [Double] {
        zip(fromMouth, toMouth).map { $0 + ($1 - $0) * Double(morph) }
    }

    private func currentGaze() -> CGPoint {
        CGPoint(x: fromGaze.x + (toGaze.x - fromGaze.x) * morph, y: fromGaze.y + (toGaze.y - fromGaze.y) * morph)
    }

    // MARK: the frame

    public func tick(now: TimeInterval) {
        lastNow = now

        if animates, let at = nextBlinkAt, now >= at {
            blinkNow()
            scheduleBlink(now: now)
        }
        if animates, now >= nextFaceAt {
            let sequence = data.expressions[expression.rawValue] ?? []
            let others = sequence.filter { $0 != faceIndex }
            setFace(others.randomElement() ?? sequence.first ?? faceIndex, hard: false, now: now)
            scheduleFace(now: now)
        }

        if morph < 1 { morph = min(1, morph + (1 - morph) * 0.18 + 0.01) }
        pointerGaze.x += (pointerGazeTarget.x - pointerGaze.x) * 0.12
        pointerGaze.y += (pointerGazeTarget.y - pointerGaze.y) * 0.12

        var blink: CGFloat = 1
        if let start = blinkStart {
            let r = CGFloat((now - start) / 0.32)
            if r >= 1 { blinkStart = nil } else { blink = max(r < 0.42 ? 1 - r / 0.42 : (r - 0.42) / 0.58, 0.04) }
        }
        var spinDegrees: CGFloat = 0
        if let start = spinStart {
            let e = CGFloat((now - start) / 0.9)
            if e >= 1 { spinStart = nil } else { spinDegrees = 360 * e }
        }
        let turn = spinDegrees * .pi / 180

        let drift = CGPoint(x: currentGaze().x * lookAround, y: currentGaze().y * lookAround)
        let eyes = currentEyes().map { points in
            FaceGeometry.Eye(points: points.map { CGPoint(x: $0.x + drift.x, y: $0.y + drift.y) })
        }
        let shift = CGPoint(x: 13.2 * pointerGaze.x, y: 8.4 * pointerGaze.y)
        let eyeRefX = CGFloat(data.eyeRefX)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(eyeLeft, FaceGeometry.eyePlacement(eyes[0], blink: blink, turn: turn, shift: shift, eyeRefX: eyeRefX))
        place(eyeRight, FaceGeometry.eyePlacement(eyes[1], blink: blink, turn: turn, shift: shift, eyeRefX: eyeRefX))
        place(mouth, FaceGeometry.mouthPlacement(eyes: eyes, mouth: currentMouth(), turn: turn, shift: shift, eyeRefX: eyeRefX))
        motion.setAffineTransform(MotionTransform.transform(
            preset: data.motion[expression.rawValue],
            elapsed: now - stateStart,
            strength: motionStrength,
            pivot: CGPoint(x: eyeRefX, y: eyeRefX),
            baseline: eyeRefX * 2
        ))
        CATransaction.commit()
    }

    private func place(_ layer: CAShapeLayer, _ placement: FaceGeometry.Placement) {
        layer.path = placement.path
        layer.setAffineTransform(placement.transform)
        layer.isHidden = !placement.visible
    }
}

/// One callback per display refresh: CADisplayLink on macOS 14, a 60 Hz timer before that.
/// Stored as AnyObject because the CADisplayLink type only exists on 14.
final class Ticker {
    private var timer: Timer?
    private var displayLink: AnyObject?
    private let tick: () -> Void

    init(view: NSView, tick: @escaping () -> Void) {
        self.tick = tick
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func fire() { tick() }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
    }

    deinit { invalidate() }
}
