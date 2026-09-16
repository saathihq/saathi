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
    }

    func testThePanelOriginCentresThePanelOnThePosition() {
        var follower = PointerFollower(start: CGPoint(x: 100, y: 100))
        _ = follower.follow(CGPoint(x: 100 - follower.offset.dx, y: 100 - follower.offset.dy), dt: 10)
        XCTAssertEqual(follower.origin(forPanelOf: CGSize(width: 72, height: 72)), CGPoint(x: 64, y: 64))
    }
}
