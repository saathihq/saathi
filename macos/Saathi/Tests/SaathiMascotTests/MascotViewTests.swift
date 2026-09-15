//
//  MascotViewTests.swift
//  SaathiMascotTests
//
//  The view is checked by eye in MascotPreview; these only pin the state it exposes and that a
//  frame can be drawn for every expression without an out-of-range face.
//

import AppKit
import XCTest
@testable import SaathiMascot

final class MascotViewTests: XCTestCase {

    private func makeView() throws -> MascotView {
        MascotView(data: try MascotData.load(), color: MascotColor(hex: "#377FE6"), expression: .idle,
                   frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    }

    func testEveryExpressionCanDrawAFrame() throws {
        let view = try makeView()
        for expression in Expression.allCases {
            view.expression = expression
            view.tick(now: 0)
            view.tick(now: 0.5)
            XCTAssertEqual(view.expression, expression)
        }
    }

    func testChangingExpressionSwitchesToItsFirstFace() throws {
        let view = try makeView()
        let data = try MascotData.load()
        view.expression = .listening
        XCTAssertEqual(view.faceIndex, data.expressions["listening"]?.first)
        view.expression = .celebrate
        XCTAssertEqual(view.faceIndex, data.expressions["celebrate"]?.first)
    }

    func testLookAtMapsTheViewToMinusOneToOne() throws {
        let view = try makeView()
        view.lookAt(CGPoint(x: 96, y: 0))       // top-right corner in flipped coordinates
        XCTAssertEqual(view.pointerGazeTarget.x, 1, accuracy: 0.001)
        XCTAssertEqual(view.pointerGazeTarget.y, -1, accuracy: 0.001)
        view.lookAt(nil)
        XCTAssertEqual(view.pointerGazeTarget, .zero)
    }

    func testAutoBlinkIsScheduledOnlyWhereTheDataAllowsIt() throws {
        let view = try makeView()
        view.expression = .idle
        XCTAssertNotNil(view.nextBlinkAt, "idle blinks")
        view.expression = .sleeping
        XCTAssertNil(view.nextBlinkAt, "sleeping does not")
    }

    func testTheViewIsFlippedSoTheJSONCoordinatesAreUsedAsIs() throws {
        XCTAssertTrue(try makeView().isFlipped)
    }

    func testAnExpressionWithNoFacesKeepsTheCurrentFaceInsteadOfCrashing() throws {
        var data = try MascotData.load()
        data.expressions["idle"] = []
        let view = MascotView(data: data, color: MascotColor(hex: "#377FE6"), expression: .idle,
                              frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        let before = view.faceIndex
        // Well past any face interval, so the cycling branch runs.
        view.tick(now: 60)
        view.tick(now: 120)
        XCTAssertEqual(view.faceIndex, before)
    }
}
