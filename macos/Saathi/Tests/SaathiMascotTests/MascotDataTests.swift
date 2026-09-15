//
//  MascotDataTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class MascotDataTests: XCTestCase {

    func testTheBundledDataLoads() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.faces.count, 25)
        XCTAssertEqual(data.mouths.count, 25)
        XCTAssertEqual(data.gaze.count, 25)
        XCTAssertTrue(data.faces.allSatisfy { $0.count == 2 }, "every face is a left and a right eye")
        XCTAssertTrue(data.faces.allSatisfy { $0.allSatisfy { $0.count == 48 } }, "every eye is 48 points")
        XCTAssertTrue(data.mouths.allSatisfy { $0.count == 4 }, "a mouth is half-width, curve, drop, tilt")
    }

    func testTheViewBoxAndTransformsAreTheOnesTheWebRendererUses() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.viewBox.x, -15)
        XCTAssertEqual(data.viewBox.width, 258.541, accuracy: 0.001)
        XCTAssertEqual(data.eyeRefX, 114.2705, accuracy: 0.0001)
        XCTAssertEqual(data.bodyTransform.scale, 0.593899, accuracy: 0.000001)
        XCTAssertEqual(data.faceTransform.scale, 0.74, accuracy: 0.000001)
    }

    func testEveryExpressionPointsAtRealFacesAndHasTiming() throws {
        let data = try MascotData.load()
        XCTAssertFalse(data.expressions.isEmpty)
        for (name, faces) in data.expressions {
            XCTAssertFalse(faces.isEmpty, "\(name) lists no faces")
            XCTAssertTrue(faces.allSatisfy { (0..<data.faces.count).contains($0) }, "\(name) points off the end")
            XCTAssertNotNil(data.faceInterval[name], "\(name) has no face interval entry")
            XCTAssertNotNil(data.blinkInterval[name], "\(name) has no blink interval entry (null is fine, absent is not)")
        }
    }

    func testMotionPresetsDecodeBothShapesOfValue() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.motion["sleeping"]?.pulse, [0.028, 4600])
        XCTAssertEqual(data.motion["sleeping"]?.tilt, 2)
        XCTAssertEqual(data.motion["working"]?.squash, 0.22)
        XCTAssertEqual(data.motion["powering-down"]?.settle, 0.05)
        XCTAssertNil(data.motion["idle"]?.bob)
    }

    func testThePaletteHasSaathiBlue() throws {
        XCTAssertEqual(try MascotData.load().palette["blue"], "#377FE6")
    }
}
