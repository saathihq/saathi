//
//  HoldToTalkTests.swift
//  SaathiKitTests
//
//  The tracker is the whole decision; the monitor only feeds it flag changes from an event tap.
//

import CoreGraphics
import XCTest
@testable import SaathiKit

final class HoldToTalkTrackerTests: XCTestCase {

    private var tracker = HoldToTalkTracker()

    func testBothKeysDownBeginsAndEitherUpEnds() {
        XCTAssertNil(tracker.update(flags: [.maskControl]))
        XCTAssertEqual(tracker.update(flags: [.maskControl, .maskAlternate]), .began)
        XCTAssertTrue(tracker.isHeld)
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate, .maskShift]), "an extra key does not end the hold")
        XCTAssertEqual(tracker.update(flags: [.maskAlternate]), .ended)
        XCTAssertFalse(tracker.isHeld)
    }

    func testRepeatedFlagChangesWhileHeldAreQuiet() {
        _ = tracker.update(flags: [.maskControl, .maskAlternate])
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate]))
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate, .maskCommand]))
    }

    func testOtherModifiersAloneNeverBegin() {
        XCTAssertNil(tracker.update(flags: [.maskCommand, .maskShift]))
        XCTAssertNil(tracker.update(flags: [.maskAlternate, .maskCommand]))
    }

    func testTheCombinationHasASpokenName() {
        XCTAssertEqual(HoldToTalkCombination.controlOption.spoken, "control and option")
    }
}

final class HoldToTalkMonitorTests: XCTestCase {
    func testStopBeforeStartIsANoOpAndDeinitIsSafe() {
        var monitor: HoldToTalkMonitor? = HoldToTalkMonitor { _ in }
        monitor?.stop()
        monitor = nil   // deinit without a tap: nothing to release, no crash
    }
    func testStartWithoutTheGrantRefusesOrInstalls() throws {
        let monitor = HoldToTalkMonitor { _ in }
        do {
            try monitor.start()
            XCTAssertTrue(HoldToTalkMonitor.isPermitted(), "installed, so the grant must be present")
            monitor.stop()
        } catch HoldToTalkError.notPermitted {
            XCTAssertFalse(HoldToTalkMonitor.isPermitted())
        }
    }
}
