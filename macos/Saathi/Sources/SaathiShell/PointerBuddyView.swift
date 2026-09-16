//
//  PointerBuddyView.swift
//  SaathiShell
//
//  The buddy itself: a 16 pt orange triangle, tipped like a pointer, with a glow of its own colour
//  around it. Small on purpose — it is company beside the pointer, not a character in the way. The
//  view is flipped so the triangle's path can be written in the same y-down terms as the drawing
//  it came from, and the 16 pt triangle is centred in a wider view so the glow has room.
//

import AppKit
import QuartzCore

@MainActor
public final class PointerBuddyView: NSView {

    /// The orange OpenClicky's buddy is drawn in.
    public static let tint = NSColor(srgbRed: 0xF0 / 255, green: 0x45 / 255, blue: 0x2B / 255, alpha: 1)
    /// The triangle's bounding box; the view around it is larger so the glow is not clipped.
    public static let triangleSide: CGFloat = 16
    /// Tipped left like a pointer's arrow.
    public static let rotation: CGFloat = -35

    private let triangle = CAShapeLayer()

    /// How far the glow spreads. 8 at rest; wider while Saathi is thinking.
    public var glowRadius: CGFloat {
        get { triangle.shadowRadius }
        set { triangle.shadowRadius = newValue }
    }

    public private(set) var isPulsing = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        let side = Self.triangleSide
        triangle.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        triangle.path = Self.trianglePath(side: side)
        triangle.fillColor = Self.tint.cgColor
        triangle.strokeColor = nil
        // The glow is the same colour as the fill, centred: a halo, not a drop shadow.
        triangle.shadowColor = Self.tint.cgColor
        triangle.shadowRadius = 8
        triangle.shadowOpacity = 1
        triangle.shadowOffset = .zero
        triangle.masksToBounds = false
        triangle.transform = CATransform3DMakeRotation(Self.rotation * .pi / 180, 0, 0, 1)
        layer?.addSublayer(triangle)
        layOutTriangle()

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Flipped so the triangle's vertices read y-down, the way the shape was drawn.
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        layOutTriangle()
    }

    /// A glow that breathes, for listening. Off, the buddy sits at full opacity.
    public func setPulsing(_ on: Bool) {
        guard on != isPulsing else { return }
        isPulsing = on
        guard on else {
            triangle.removeAnimation(forKey: "pulse")
            triangle.opacity = 1
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.6
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        triangle.add(pulse, forKey: "pulse")
    }

    private func layOutTriangle() {
        triangle.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// An equilateral triangle pointing up, in a y-down box of `side` points. Its tip pokes a
    /// little above the box, which is what gives the pointer its lean rather than a squat wedge.
    static func trianglePath(side: CGFloat) -> CGPath {
        let height = side * sqrt(3) / 2
        let mid = side / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid, y: mid - height / 1.5))
        path.addLine(to: CGPoint(x: 0, y: mid + height / 3))
        path.addLine(to: CGPoint(x: side, y: mid + height / 3))
        path.closeSubpath()
        return path
    }
}
