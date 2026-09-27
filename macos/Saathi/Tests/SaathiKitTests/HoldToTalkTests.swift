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

/// Every shortcut on the Home panel, as a sequence of modifier changes at given times.
final class ShortcutTrackerTests: XCTestCase {

    private var tracker = ShortcutTracker()
    private let none: CGEventFlags = []
    private let control: CGEventFlags = [.maskControl]
    private let fnControl: CGEventFlags = [.maskControl, .maskSecondaryFn]

    private func at(_ flags: CGEventFlags, _ time: TimeInterval) -> [ShortcutEvent] {
        tracker.update(flags: flags, at: time)
    }

    func testTalkIsControlAndOptionHeld() {
        XCTAssertEqual(at(control, 0), [])
        XCTAssertEqual(at([.maskControl, .maskAlternate], 0.05), [.talkBegan])
        XCTAssertEqual(at(control, 2), [.talkEnded])
        XCTAssertEqual(at(none, 2.05), [], "releasing control after talking is not a Text tap")
        XCTAssertEqual(at(control, 2.2), [])
        XCTAssertEqual(at(none, 2.3), [], "one clean tap after a talk is still only one")
    }

    func testTextIsControlTappedTwice() {
        XCTAssertEqual(at(control, 0), [])
        XCTAssertEqual(at(none, 0.1), [])
        XCTAssertEqual(at(control, 0.3), [])
        XCTAssertEqual(at(none, 0.4), [.textRequested])
        XCTAssertEqual(at(control, 0.5), [])
        XCTAssertEqual(at(none, 0.6), [], "a third tap starts over rather than opening it again")
    }

    func testControlTapsTooFarApartOrTooLongAreNotText() {
        _ = at(control, 0); _ = at(none, 0.1)
        _ = at(control, 1.5)
        XCTAssertEqual(at(none, 1.6), [], "a second tap a second later is a new first tap")
        _ = at(control, 3); _ = at(none, 3.1)
        _ = at(control, 3.2)
        XCTAssertEqual(at(none, 3.8), [], "held too long to be a tap")
    }

    /// Control-C, control-C: two quick control presses with a key inside each. Not Text.
    func testAKeyPressedWithControlSpoilsTheTap() {
        _ = at(control, 0); tracker.keyPressed(); _ = at(none, 0.1)
        _ = at(control, 0.2); tracker.keyPressed()
        XCTAssertEqual(at(none, 0.3), [])
    }

    func testDictateIsFnAndControlHeld() {
        XCTAssertEqual(at([.maskSecondaryFn], 0), [])
        XCTAssertEqual(at(fnControl, 0.05), [.dictateBegan])
        XCTAssertTrue(tracker.isDictating)
        XCTAssertEqual(at([.maskSecondaryFn], 2), [.dictateEnded])
        XCTAssertEqual(at(none, 2.05), [])
    }

    func testHandsFreeIsFnAndControlTappedTwice() {
        XCTAssertEqual(at(fnControl, 0), [.dictateBegan])
        XCTAssertEqual(at(none, 0.1), [.dictateCancelled], "a tap is too short to have been dictation")
        XCTAssertEqual(at(fnControl, 0.3), [.handsFreeToggled])
        XCTAssertEqual(at(none, 0.4), [], "the second press does not also dictate")
        XCTAssertEqual(at(fnControl, 2), [.dictateBegan], "and the next press is a dictation again")
    }

    func testFnAndControlTapsAreNeverText() {
        _ = at(fnControl, 0); _ = at(none, 0.1)
        _ = at(fnControl, 0.2)
        XCTAssertFalse(at(none, 0.3).contains(.textRequested))
    }

    func testTalkWinsOverADictationStartingOnTheSameKeys() {
        XCTAssertEqual(at(fnControl, 0), [.dictateBegan])
        XCTAssertEqual(at([.maskControl, .maskSecondaryFn, .maskAlternate], 0.05), [.dictateCancelled, .talkBegan])
    }
}
