//
//  FaceGeometry.swift
//  SaathiMascot
//
//  Where the eyes and mouth go for one face, ported from the web renderer's draw loop. The face
//  is treated as wrapped around a head of radius 105: turning it slides features sideways and
//  narrows them, and a feature past the edge is hidden. Pure functions — no layers, no clocks —
//  so the port can be checked with numbers.
//

import CoreGraphics
import Foundation

enum FaceGeometry {

    struct Eye {
        var points: [CGPoint]

        var centroid: CGPoint {
            let n = CGFloat(points.count)
            return CGPoint(
                x: points.reduce(0) { $0 + $1.x } / n,
                y: points.reduce(0) { $0 + $1.y } / n
            )
        }

        var halfHeight: CGFloat {
            let ys = points.map(\.y)
            return ((ys.max() ?? 0) - (ys.min() ?? 0)) / 2
        }
    }

    /// A path in face units plus the transform that places it, and whether it faces the viewer.
    struct Placement {
        var path: CGPath
        var transform: CGAffineTransform
        var visible: Bool
    }

    /// Radius of the imaginary head the face wraps around, in face units.
    static let headRadius: CGFloat = 105
    /// Scale limits the web renderer clamps to, so a feature never collapses or explodes.
    static let scaleRange: ClosedRange<CGFloat> = 0.02...2.4

    static func eyes(from face: [[[Double]]], drift: CGPoint) -> [Eye] {
        face.map { eye in
            Eye(points: eye.map { CGPoint(x: CGFloat($0[0]) + drift.x, y: CGFloat($0[1]) + drift.y) })
        }
    }

    static func eyePlacement(_ eye: Eye, blink: CGFloat, turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement {
        let c = eye.centroid
        let restAngle = asin(clamp((c.x - eyeRefX) / headRadius, -1...1))
        let angle = restAngle + turn
        let facing = cos(angle)
        let narrowing = max(facing, 0.02) / max(cos(restAngle), 0.02)

        let path = CGMutablePath()
        path.addLines(between: eye.points)
        path.closeSubpath()

        let transform = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: clamp(narrowing, scaleRange), y: clamp(blink, scaleRange)))
            .concatenating(CGAffineTransform(translationX: eyeRefX + headRadius * sin(angle) + shift.x, y: c.y + shift.y))

        return Placement(path: path, transform: transform, visible: facing > 0.02)
    }

    static func mouthPlacement(eyes: [Eye], mouth: [Double], turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement {
        let left = eyes[0].centroid, right = eyes[1].centroid
        let halfWidth = CGFloat(mouth[0]), curve = CGFloat(mouth[1]), drop = CGFloat(mouth[2]), tilt = CGFloat(mouth[3])

        let across = atan2(right.y - left.y, right.x - left.x)
        let distance = (eyes.map(\.halfHeight).max() ?? 0) + drop
        let centre = CGPoint(
            x: (left.x + right.x) / 2 - sin(across) * distance,
            y: (left.y + right.y) / 2 + cos(across) * distance
        )
        let angle = across + tilt * .pi / 180

        let restAngle = asin(clamp((centre.x - eyeRefX) / headRadius, -1...1))
        let turned = restAngle + turn
        let facing = cos(turned)
        let stretch = max(facing, 0.02) / max(cos(restAngle), 0.02)

        let ct = cos(angle), st = sin(angle)
        func rotated(_ along: CGFloat, _ down: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + along * ct - down * st, y: centre.y + along * st + down * ct)
        }
        let path = CGMutablePath()
        path.move(to: rotated(-halfWidth, 0))
        path.addQuadCurve(to: rotated(halfWidth, 0), control: rotated(0, curve))

        let transform = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(CGAffineTransform(scaleX: clamp(stretch, scaleRange), y: 1))
            .concatenating(CGAffineTransform(translationX: eyeRefX + headRadius * sin(turned) + shift.x, y: centre.y + shift.y))

        return Placement(path: path, transform: transform, visible: facing > 0.02)
    }

    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
