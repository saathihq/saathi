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

    /// Leaving the island to hold the keys is the ordinary thing to do. The open island lives out
    /// its grace and then becomes the strip; it does not snap shut the instant listening starts.
    func testGettingBusyDuringTheGraceDoesNotCutItShort() {
        var hover = IslandHover()
        hover.setHovering(true, now: 0)
        hover.setHovering(false, now: 1)
        XCTAssertEqual(hover.setBusy(true, now: 1.1), .open, "still inside the grace")
        XCTAssertEqual(hover.tick(now: 1.3), .open)
        XCTAssertEqual(hover.tick(now: 1.41), .compact, "the grace ends in the strip, because Saathi is busy")
        hover.setBusy(false, now: 2)
        XCTAssertEqual(hover.tick(now: 2.41), .collapsed)
    }
}
