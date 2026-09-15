//
//  MascotViewTests.swift
//  SaathiMascotTests
//
//  The view is checked by eye in MascotPreview; these only pin the state it exposes and that a
//  frame can be drawn for every expression without an out-of-range face.
//

import AppKit
import QuartzCore
import XCTest
@testable import SaathiMascot

final class MascotViewTests: XCTestCase {

    /// A view whose clock the test owns: `clock.value` is what `now()` returns.
    final class Clock { var value: TimeInterval = 1_000 }

    private func makeView(expression: MascotExpression = .idle, data: MascotData? = nil) throws -> (MascotView, Clock) {
        let clock = Clock()
        let view = MascotView(data: try data ?? MascotData.load(), color: MascotColor(hex: "#377FE6"), expression: expression,
                              frame: NSRect(x: 0, y: 0, width: 96, height: 96), now: { clock.value })
        return (view, clock)
    }

    func testEveryExpressionCanDrawAFrame() throws {
        let (view, clock) = try makeView()
        for expression in MascotExpression.allCases {
            view.expression = expression
            clock.value += 0.5
            view.tick(now: clock.value)
            // Past every face and blink interval, so the cycling and blink branches run too.
            clock.value += 30
            view.tick(now: clock.value)
            XCTAssertEqual(view.expression, expression)
            XCTAssertTrue(view.lastMotion.a.isFinite && view.lastMotion.d.isFinite, "\(expression) produced a non-finite transform")
            XCTAssertLessThan(abs(view.lastMotion.a), 10, "\(expression) scaled implausibly large")
        }
    }

    func testChangingExpressionSwitchesToItsFirstFace() throws {
        let (view, _) = try makeView()
        let data = try MascotData.load()
        view.expression = .listening
        XCTAssertEqual(view.faceIndex, data.expressions["listening"]?.first)
        view.expression = .celebrate
        XCTAssertEqual(view.faceIndex, data.expressions["celebrate"]?.first)
    }

    func testLookAtMapsTheViewToMinusOneToOne() throws {
        let (view, _) = try makeView()
        view.lookAt(CGPoint(x: 96, y: 0))       // top-right corner in flipped coordinates
        XCTAssertEqual(view.pointerGazeTarget.x, 1, accuracy: 0.001)
        XCTAssertEqual(view.pointerGazeTarget.y, -1, accuracy: 0.001)
        view.lookAt(nil)
        XCTAssertEqual(view.pointerGazeTarget, .zero)
    }

    func testAutoBlinkIsScheduledOnlyWhereTheDataAllowsIt() throws {
        let (view, _) = try makeView()
        view.expression = .idle
        XCTAssertNotNil(view.nextBlinkAt, "idle blinks")
        view.expression = .sleeping
        XCTAssertNil(view.nextBlinkAt, "sleeping does not")
    }

    func testTheViewIsFlippedSoTheJSONCoordinatesAreUsedAsIs() throws {
        let (view, _) = try makeView()
        XCTAssertTrue(view.isFlipped)
    }

    func testAnExpressionWithNoFacesKeepsTheCurrentFaceInsteadOfCrashing() throws {
        var data = try MascotData.load()
        data.expressions["idle"] = []
        let (view, clock) = try makeView(expression: .idle, data: data)
        let before = view.faceIndex
        // Well past any face interval, so the cycling branch runs.
        clock.value += 60
        view.tick(now: clock.value)
        clock.value += 60
        view.tick(now: clock.value)
        XCTAssertEqual(view.faceIndex, before)
    }

    func testTheClockStartsAtConstruction() throws {
        let (view, _) = try makeView()   // idle: blinks every 6–14 s
        XCTAssertEqual(view.stateStart, 1_000)
        let nextBlinkAt = try XCTUnwrap(view.nextBlinkAt)
        XCTAssertGreaterThan(nextBlinkAt, 1_006)
        XCTAssertLessThanOrEqual(nextBlinkAt, 1_014)
    }
}
