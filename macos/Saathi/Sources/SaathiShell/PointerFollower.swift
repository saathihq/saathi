//
//  PointerFollower.swift
//  SaathiShell
//
//  Where the companion sits relative to the pointer, eased so it trails rather than jitters.
//  Screen coordinates (y up). Pure, so the easing can be tested with numbers.
//

import CoreGraphics
import Foundation

public struct PointerFollower: Equatable {
    /// Right of and below the pointer, so it never covers what is being pointed at.
    public var offset = CGVector(dx: 28, dy: -36)
    /// Seconds to close about two-thirds of the remaining gap.
    public var response: TimeInterval = 0.12
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

    /// The panel's bottom-left so the character is centred on the position.
    public func origin(forPanelOf size: CGSize) -> CGPoint {
        CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2)
    }
}
