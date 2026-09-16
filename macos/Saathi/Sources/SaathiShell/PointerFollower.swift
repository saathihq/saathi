//
//  PointerFollower.swift
//  SaathiShell
//
//  Where the buddy sits relative to the pointer, eased so it trails rather than jitters.
//  Screen coordinates (y up). Pure, so the easing can be tested with numbers.
//

import CoreGraphics
import Foundation

public struct PointerFollower: Equatable {
    /// Right of and below the pointer, so it never covers what is being pointed at. OpenClicky's
    /// buddy sits 35 pt right and 25 pt below the hotspot; screen y goes up, so `dy` is negative.
    public var offset = CGVector(dx: 35, dy: -25)
    /// Seconds to close about two-thirds of the remaining gap. OpenClicky uses a SwiftUI spring of
    /// response 0.2 s and damping 0.6; an exponential ease this quick reads the same at a glance —
    /// it lands without the spring's overshoot, which a pointer-sized buddy would only read as jitter.
    public var response: TimeInterval = 0.07
    public private(set) var position: CGPoint

    public init(start: CGPoint) {
        position = start
    }

    @discardableResult
    public mutating func follow(_ pointer: CGPoint, dt: TimeInterval) -> CGPoint {
        guard dt > 0 else { return position }
        let target = CGPoint(x: pointer.x + offset.dx, y: pointer.y + offset.dy)
        let k = 1 - exp(-dt / response)
        position.x += (target.x - position.x) * k
        position.y += (target.y - position.y) * k
        return position
    }

    /// The panel's bottom-left so the buddy is centred on the position.
    public func origin(forPanelOf size: CGSize) -> CGPoint {
        CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2)
    }
}
