//
//  IslandHoverTests.swift
//  SaathiShellTests
//

import XCTest
@testable import SaathiShell

final class IslandHoverTests: XCTestCase {

    func testReachingTheTopOfTheScreenOpensTheIslandAtOnce() {
        var hover = IslandHover()
        XCTAssertEqual(hover.state, .collapsed)
        XCTAssertEqual(hover.setHovering(true, now: 0), .open)
    }

    func testLeavingKeepsItOpenForTheGraceAndThenCollapses() {
        var hover = IslandHover()
        hover.setHovering(true, now: 0)
        XCTAssertEqual(hover.setHovering(false, now: 0), .open, "leaving does not close it on the spot")
        XCTAssertEqual(hover.tick(now: 0.39), .open)
        XCTAssertEqual(hover.tick(now: 0.4), .collapsed)
    }

    func testPollingWhileAwayDoesNotKeepRearmingTheGrace() {
        var hover = IslandHover()
        hover.setHovering(true, now: 0)
        hover.setHovering(false, now: 0)
        // The panel polls every 50 ms; a repeated "not hovering" must not push the deadline out.
        for step in stride(from: 0.05, through: 0.35, by: 0.05) {
            hover.setHovering(false, now: step)
            XCTAssertEqual(hover.tick(now: step), .open)
        }
        hover.setHovering(false, now: 0.4)
        XCTAssertEqual(hover.tick(now: 0.4), .collapsed)
    }

    func testGettingBusyOpensTheCompactStrip() {
        var hover = IslandHover()
        XCTAssertEqual(hover.setBusy(true, now: 0), .compact)
    }

    func testGoingIdleCollapsesTheStripAfterTheGrace() {
        var hover = IslandHover()
        hover.setBusy(true, now: 0)
        XCTAssertEqual(hover.setBusy(false, now: 1), .compact)
        XCTAssertEqual(hover.tick(now: 1.39), .compact)
        XCTAssertEqual(hover.tick(now: 1.4), .collapsed)
    }

    func testHoveringWhileBusyOpensFullyAndFallsBackToTheStrip() {
        var hover = IslandHover()
        hover.setBusy(true, now: 0)
        XCTAssertEqual(hover.setHovering(true, now: 0), .open, "the pointer wins over the strip")
        hover.setHovering(false, now: 1)
        XCTAssertEqual(hover.tick(now: 1.4), .compact, "still busy, so the strip stays")
    }

    func testBusyArrivingWhileHoveringDoesNotShrinkTheIsland() {
        var hover = IslandHover()
        hover.setHovering(true, now: 0)
        XCTAssertEqual(hover.setBusy(true, now: 0.1), .open)
    }

    func testComingBackDuringTheGraceCancelsTheCollapse() {
        var hover = IslandHover()
        hover.setHovering(true, now: 0)
        hover.setHovering(false, now: 0)
        XCTAssertEqual(hover.setHovering(true, now: 0.2), .open)
        XCTAssertEqual(hover.tick(now: 5), .open, "the pending collapse was cancelled")
    }

    func testTheGraceIsConfigurable() {
        var hover = IslandHover()
        hover.grace = 1
        hover.setHovering(true, now: 0)
        hover.setHovering(false, now: 0)
        XCTAssertEqual(hover.tick(now: 0.5), .open)
        XCTAssertEqual(hover.tick(now: 1), .collapsed)
    }
}
