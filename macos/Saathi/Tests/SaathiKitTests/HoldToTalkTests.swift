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
