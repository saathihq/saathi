//
//  PointerFollowerTests.swift
//  SaathiShellTests
//

import XCTest
@testable import SaathiShell

final class PointerFollowerTests: XCTestCase {

    func testNoTimeMeansNoMovement() {
        var follower = PointerFollower(start: CGPoint(x: 100, y: 100))
        XCTAssertEqual(follower.follow(CGPoint(x: 500, y: 500), dt: 0), CGPoint(x: 100, y: 100))
    }

    func testItApproachesThePointerPlusTheOffsetAndGetsThereGivenTime() {
        var follower = PointerFollower(start: CGPoint(x: 0, y: 0))
        let pointer = CGPoint(x: 300, y: 200)
        let target = CGPoint(x: pointer.x + follower.offset.dx, y: pointer.y + follower.offset.dy)
        let first = follower.follow(pointer, dt: 1.0 / 60)
        XCTAssertGreaterThan(first.x, 0)
        XCTAssertLessThan(first.x, target.x)
        for _ in 0..<600 { _ = follower.follow(pointer, dt: 1.0 / 60) }
        XCTAssertEqual(follower.position.x, target.x, accuracy: 0.01)
        XCTAssertEqual(follower.position.y, target.y, accuracy: 0.01)
    }

    func testTheOffsetSitsBelowAndToTheRightOfThePointerInScreenCoordinates() {
        let follower = PointerFollower(start: .zero)
        XCTAssertGreaterThan(follower.offset.dx, 0, "right")
        XCTAssertLessThan(follower.offset.dy, 0, "below — screen y goes up")
        XCTAssertEqual(follower.offset.dx, 35, "OpenClicky's buddy offset")
        XCTAssertEqual(follower.offset.dy, -25)
    }

    func testThePanelOriginCentresThePanelOnThePosition() {
        var follower = PointerFollower(start: CGPoint(x: 100, y: 100))
        // The pointer that parks the buddy on (100, 100) is 35 pt to its left and 25 pt above it.
        _ = follower.follow(CGPoint(x: 65, y: 125), dt: 10)
        XCTAssertEqual(follower.position.x, 100, accuracy: 0.000_1)
        XCTAssertEqual(follower.position.y, 100, accuracy: 0.000_1)
        // The buddy panel is 48 pt square, so its bottom-left is 24 pt below and left of centre.
        XCTAssertEqual(follower.origin(forPanelOf: CGSize(width: 48, height: 48)), CGPoint(x: 76, y: 76))
    }
}
