//
//  SVGPathTests.swift
//  SaathiMascotTests
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class SVGPathTests: XCTestCase {

    func testMoveCurveAndCloseProduceTheExpectedBounds() throws {
        let path = try SVGPath.cgPath(from: "M0 0 C1 1 2 2 3 3 Z")
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 3, height: 3))
    }

    func testLinesAndCommasAndNegativeNumbersAreAccepted() throws {
        let path = try SVGPath.cgPath(from: "M-1,-1 L2,3 L2 -1 Z")
        XCTAssertEqual(path.boundingBox, CGRect(x: -1, y: -1, width: 3, height: 4))
    }

    func testARunOfCurvesAfterOneCommandLetter() throws {
        // SVG lets one C carry several sextuplets.
        let path = try SVGPath.cgPath(from: "M0 0 C0 1 1 1 1 0 1 -1 2 -1 2 0")
        XCTAssertEqual(path.boundingBox.width, 2, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint, CGPoint(x: 2, y: 0))
    }

    func testUnsupportedCommandsAreAnErrorNotAGuess() {
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 Q1 1 2 2")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .unsupportedCommand("Q"))
        }
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 c1 1 2 2 3 3")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .unsupportedCommand("c"))
        }
    }

    func testWrongArgumentCountsAreAnError() {
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 C1 1 2 2")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .wrongArgumentCount(command: "C", found: 4))
        }
    }

    func testTheMascotBodyParsesAndFitsItsSquareOnceTransformed() throws {
        let data = try MascotData.load()
        let raw = try SVGPath.cgPath(from: data.bodyPath)
        var transform = data.bodyTransform.affine
        let body = try XCTUnwrap(raw.copy(using: &transform))
        let box = body.boundingBoxOfPath   // tight; `boundingBox` would include control points
        let square = CGFloat(data.eyeRefX) * 2   // the 228.541 inner square the character stands in
        // The pointer stands on the bottom edge and reaches the top; sideways it sits inside.
        XCTAssertEqual(box.minY, 0, accuracy: 0.5)
        XCTAssertEqual(box.maxY, square, accuracy: 0.5)
        XCTAssertGreaterThan(box.minX, 0)
        XCTAssertLessThan(box.maxX, square)
        XCTAssertGreaterThan(box.width, 150)
    }

    func testExponentNotationIsOneNumber() throws {
        let path = try SVGPath.cgPath(from: "M0 0 L1e-2 3 L2E1 3")
        XCTAssertEqual(path.currentPoint, CGPoint(x: 20, y: 3))
        XCTAssertEqual(path.boundingBoxOfPath.minX, 0)
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 20)
    }

    func testAMalformedNumberIsAnError() {
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 L1..2 3")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .malformedNumber("1..2"))
        }
    }
}
