//
//  FaceGeometryTests.swift
//  SaathiMascotTests
//
//  The maths is a port of the web renderer's draw loop. These pin the properties a face must have
//  at rest, on a blink, and when turned away — with numbers, not pixels.
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class FaceGeometryTests: XCTestCase {

    private var data: MascotData!
    private var eyes: [FaceGeometry.Eye]!

    override func setUpWithError() throws {
        data = try MascotData.load()
        eyes = FaceGeometry.eyes(from: data.faces[1], drift: .zero)   // the "listening" face
    }

    func testAtRestAnEyeStaysWhereItWasDrawn() {
        for eye in eyes {
            let placement = FaceGeometry.eyePlacement(eye, blink: 1, turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
            let moved = eye.centroid.applying(placement.transform)
            XCTAssertEqual(moved.x, eye.centroid.x, accuracy: 0.001)
            XCTAssertEqual(moved.y, eye.centroid.y, accuracy: 0.001)
            XCTAssertTrue(placement.visible)
            XCTAssertGreaterThan(placement.path.boundingBox.width, 5, "a real outline, not a point")
        }
    }

    func testABlinkSquashesTheEyeVertically() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 0.04, turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        XCTAssertEqual(placement.transform.d, 0.04, accuracy: 0.0001, "y scale is the blink")
        XCTAssertEqual(placement.transform.a, 1, accuracy: 0.0001, "x scale is untouched")
    }

    func testAFullTurnHidesTheEyes() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 1, turn: .pi, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        XCTAssertFalse(placement.visible)
    }

    func testThePointerShiftMovesTheEyeByTheSameAmount() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 1, turn: 0, shift: CGPoint(x: 5, y: -3), eyeRefX: CGFloat(data.eyeRefX))
        let moved = eyes[0].centroid.applying(placement.transform)
        XCTAssertEqual(moved.x, eyes[0].centroid.x + 5, accuracy: 0.001)
        XCTAssertEqual(moved.y, eyes[0].centroid.y - 3, accuracy: 0.001)
    }

    func testTheMouthSitsBelowBothEyes() {
        let placement = FaceGeometry.mouthPlacement(eyes: eyes, mouth: data.mouths[1], turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        let lowestEye = max(eyes[0].centroid.y, eyes[1].centroid.y)
        XCTAssertGreaterThan(placement.path.boundingBox.minY, lowestEye, "y is down; the mouth is under the eyes")
        XCTAssertTrue(placement.visible)
        XCTAssertEqual(placement.path.boundingBox.width, CGFloat(data.mouths[1][0]) * 2, accuracy: 0.5, "as wide as twice the half-width")
    }

    func testTurningTheHeadNarrowsAndThenHidesTheMouth() {
        let eyeRefX = CGFloat(data.eyeRefX)
        let rest = FaceGeometry.mouthPlacement(eyes: eyes, mouth: data.mouths[1], turn: 0, shift: .zero, eyeRefX: eyeRefX)
        let quarter = FaceGeometry.mouthPlacement(eyes: eyes, mouth: data.mouths[1], turn: .pi / 4, shift: .zero, eyeRefX: eyeRefX)
        let away = FaceGeometry.mouthPlacement(eyes: eyes, mouth: data.mouths[1], turn: .pi, shift: .zero, eyeRefX: eyeRefX)
        XCTAssertTrue(rest.visible)
        XCTAssertTrue(quarter.visible)
        XCTAssertLessThan(quarter.transform.a, rest.transform.a, "a quarter turn narrows the mouth")
        XCTAssertGreaterThan(quarter.transform.a, 0.3)
        XCTAssertFalse(away.visible, "turned right round, the mouth is on the far side")
    }

    func testDriftMovesTheWholeFace() {
        let drifted = FaceGeometry.eyes(from: data.faces[1], drift: CGPoint(x: 2, y: 4))
        XCTAssertEqual(drifted[0].centroid.x, eyes[0].centroid.x + 2, accuracy: 0.001)
        XCTAssertEqual(drifted[1].centroid.y, eyes[1].centroid.y + 4, accuracy: 0.001)
    }
}
