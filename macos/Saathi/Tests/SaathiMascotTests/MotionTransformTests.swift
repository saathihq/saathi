//
//  MotionTransformTests.swift
//  SaathiMascotTests
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class MotionTransformTests: XCTestCase {

    private let pivot = CGPoint(x: 114.2705, y: 114.2705)
    private let baseline: CGFloat = 228.541

    private func preset(_ name: String) throws -> MascotData.MotionPreset? {
        try MascotData.load().motion[name]
    }

    func testNoPresetAndZeroStrengthAreTheIdentity() throws {
        XCTAssertEqual(MotionTransform.transform(preset: nil, elapsed: 1, strength: 1, pivot: pivot, baseline: baseline), .identity)
        XCTAssertEqual(MotionTransform.transform(preset: try preset("excited"), elapsed: 1, strength: 0, pivot: pivot, baseline: baseline), .identity)
    }

    func testIdleStartsAtRest() throws {
        // idle is a pulse only; sin(0) == 0 so at t = 0 there is nothing to see.
        let t = MotionTransform.transform(preset: try preset("idle"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(t.a, 1, accuracy: 1e-9); XCTAssertEqual(t.d, 1, accuracy: 1e-9)
        XCTAssertEqual(t.tx, 0, accuracy: 1e-9); XCTAssertEqual(t.ty, 0, accuracy: 1e-9)
    }

    func testSleepingTiltsByTwoDegreesAroundThePivot() throws {
        let t = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(atan2(t.b, t.a) * 180 / .pi, 2, accuracy: 1e-6)
        let stillPivot = pivot.applying(t)
        XCTAssertEqual(stillPivot.x, pivot.x, accuracy: 1e-6)
        XCTAssertEqual(stillPivot.y, pivot.y, accuracy: 1e-6)
    }

    func testAPulseIsLargestAQuarterPeriodIn() throws {
        // sleeping: pulse [0.028, 4600 ms]
        let t = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 1.15, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(hypot(t.a, t.b), 1.028, accuracy: 1e-6)
    }

    func testABobLiftsTheBodyAQuarterPeriodIn() throws {
        // listening: bob [2, 2600 ms] — y is down, so a lift is negative.
        let t = MotionTransform.transform(preset: try preset("listening"), elapsed: 0.65, strength: 1, pivot: pivot, baseline: baseline)
        let moved = pivot.applying(t)
        XCTAssertLessThan(moved.y, pivot.y - 1.9)
    }

    func testStrengthScalesEverything() throws {
        let full = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        let half = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 0.5, pivot: pivot, baseline: baseline)
        XCTAssertEqual(atan2(half.b, half.a), atan2(full.b, full.a) / 2, accuracy: 1e-9)
    }

    func testSquashKeepsTheBaselineStill() throws {
        // working: bob [2.5, 900] + squash 0.22. Three-quarters through the period the bob wave is
        // -1, the body is at the bottom of its travel and squashed; the baseline must not move.
        let t = MotionTransform.transform(preset: try preset("working"), elapsed: 0.675, strength: 1, pivot: pivot, baseline: baseline)
        let foot = CGPoint(x: pivot.x, y: baseline).applying(t)
        XCTAssertEqual(foot.x, pivot.x, accuracy: 1e-6)
        XCTAssertEqual(foot.y, baseline + 2.5, accuracy: 1e-6, "only the bob moves it")
    }

    func testSquashHappensBeforeTheTurnSoTheFootStaysOnTheBaseline() throws {
        // playful: bob [6, 620], sway [5, 1240], squash 0.3. Three-quarters through the bob
        // period the body is at the bottom of its travel and squashed; the sway is then at 3/8 of
        // its own period, a tilt of 5·sin(135°) degrees. Squash first leaves the foot on the
        // baseline, so only the tilt and the bob move it; squash after the tilt would stretch the
        // foot's x by 15% and this would fail.
        let t = MotionTransform.transform(preset: try preset("playful"), elapsed: 0.465, strength: 1, pivot: pivot, baseline: baseline)
        let foot = CGPoint(x: pivot.x, y: baseline).applying(t)
        let tilt = 5 * sin(0.375 * 2 * CGFloat.pi) * .pi / 180
        let reach = baseline - pivot.y
        XCTAssertEqual(foot.x, pivot.x - reach * sin(tilt), accuracy: 1e-6)
        XCTAssertEqual(foot.y, pivot.y + reach * cos(tilt) + 6, accuracy: 1e-6)
    }
}
