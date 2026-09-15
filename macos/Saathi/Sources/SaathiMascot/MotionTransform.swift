//
//  MotionTransform.swift
//  SaathiMascot
//
//  How the whole body moves while an expression is held: a port of the web renderer's
//  motionTransform. Everything is a function of elapsed time, so there is no state to get wrong.
//

import CoreGraphics
import Foundation

enum MotionTransform {

    /// - Parameters:
    ///   - pivot: where rotation and scaling turn about — the centre of the drawing.
    ///   - baseline: the y the body stands on; a squash flattens toward it.
    static func transform(
        preset: MascotData.MotionPreset?,
        elapsed: TimeInterval,
        strength: CGFloat,
        pivot: CGPoint,
        baseline: CGFloat
    ) -> CGAffineTransform {
        guard let preset, strength > 0 else { return .identity }
        let ms = max(0, elapsed * 1000)

        func wave(_ period: Double, _ phase: Double = 0) -> CGFloat {
            CGFloat(sin(ms / period * .pi * 2 + phase))
        }

        var dx: CGFloat = 0, dy: CGFloat = 0
        var rotationDegrees: CGFloat = preset.tilt.map { CGFloat($0) * strength } ?? 0
        var scale: CGFloat = 1
        var squashX: CGFloat = 1, squashY: CGFloat = 1

        if let bob = preset.bob {
            let w = wave(bob[1])
            dy -= CGFloat(bob[0]) * strength * w
            if let squash = preset.squash {
                let amount = CGFloat(squash) * strength * max(0, -w)
                squashY = 1 - 0.5 * amount
                squashX = 1 + 0.5 * amount
            }
        }
        if let circle = preset.circle {
            dx += CGFloat(circle[0]) * strength * wave(circle[1])
            dy += CGFloat(circle[0]) * strength * wave(circle[1], .pi / 2)
        }
        if let sway = preset.sway {
            rotationDegrees += CGFloat(sway[0]) * strength * wave(sway[1])
        }
        if let pulse = preset.pulse {
            scale *= 1 + CGFloat(pulse[0]) * strength * wave(pulse[1])
        }
        if let jitter = preset.jitter {
            dx += CGFloat(jitter[0]) * strength * wave(jitter[1])
            dy += CGFloat(jitter[0]) * strength * wave(0.63 * jitter[1], 1.1)
        }
        if let enter = preset.enter {
            let progress = ms / enter[1]
            if progress < 1 {
                let r = progress - 1
                let ease = 1 + 2.7 * r * r * r + 1.7 * r * r
                let grown = enter[0] + (1 - enter[0]) * ease
                // The departure from 1 (fully grown) is scaled by strength, not the raw value.
                scale *= 1 + (CGFloat(grown) - 1) * strength
            }
        }
        if let settle = preset.settle {
            let p = min(max(ms / 1400, 0), 1)
            let eased = p < 0.5 ? 2 * p * p : 1 - 2 * (1 - p) * (1 - p)
            scale *= 1 + CGFloat(settle - 1) * CGFloat(eased) * strength
        }

        // Same order as the SVG transform list: squash about the baseline first, then scale and
        // rotate about the pivot, then translate.
        let squash = about(CGPoint(x: pivot.x, y: baseline), CGAffineTransform(scaleX: squashX, y: squashY))
        let grow = about(pivot, CGAffineTransform(scaleX: scale, y: scale))
        let turn = about(pivot, CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180))
        let slide = CGAffineTransform(translationX: dx, y: dy)
        return squash.concatenating(grow).concatenating(turn).concatenating(slide)
    }

    private static func about(_ centre: CGPoint, _ transform: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(transform)
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }
}
