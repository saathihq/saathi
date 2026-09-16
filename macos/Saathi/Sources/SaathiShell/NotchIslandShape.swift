//
//  NotchIslandShape.swift
//  SaathiShell
//
//  The island's outline, ported from OpenClicky's `NotchIslandShape` (NotchHUD.swift).
//
//  The top corners flare *outward* rather than being square: the shape is at its full width along
//  the very top edge and curves inward to the body's width a few points down. That is what makes an
//  open island read as something growing out of the notch instead of a rectangle appearing under
//  it, and it is the single most recognisable part of the look.
//
//  `animatableData` matters as much as the path. Without it SwiftUI cannot interpolate the radius
//  and the flare, so a spring would move the frame while the corners snapped — which is the same
//  class of mismatch as animating the backdrop apart from its content.
//

import SwiftUI

struct NotchIslandShape: Shape {
    var bottomCornerRadius: CGFloat
    var topCornerFlare: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomCornerRadius, topCornerFlare) }
        set { bottomCornerRadius = newValue.first; topCornerFlare = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let flare = min(topCornerFlare, rect.width / 2)
        let bodyMinX = rect.minX + flare
        let bodyMaxX = rect.maxX - flare
        let radius = min(bottomCornerRadius, (bodyMaxX - bodyMinX) / 2, rect.height - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Top-right flare: a quarter curve from the menu bar down into the island's straight side.
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.minY + flare), control: CGPoint(x: bodyMaxX, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: bodyMaxX - radius, y: rect.maxY - radius), radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: bodyMinX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: bodyMinX + radius, y: rect.maxY - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: bodyMinX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
