//
//  MascotColorTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class MascotColorTests: XCTestCase {

    func testMixMatchesTheWebRendererRounding() {
        XCTAssertEqual(MascotColor.mix("#000000", "#ffffff", 0.5), "#808080")
        XCTAssertEqual(MascotColor.mix("#377FE6", "#ffffff", 0), "#377fe6")
        XCTAssertEqual(MascotColor.mix("#377FE6", "#ffffff", 1), "#ffffff")
    }

    func testTheGradientEndsAreLighterAndDarkerThanTheBase() {
        let blue = MascotColor(hex: "#377FE6")
        XCTAssertEqual(blue.light, MascotColor.mix("#377FE6", "#ffffff", 0.55))
        XCTAssertEqual(blue.dark, MascotColor.mix("#377FE6", "#000000", 0.42))
    }

    func testPaletteLookup() throws {
        let data = try MascotData.load()
        XCTAssertEqual(MascotColor(paletteName: "blue", in: data)?.hex, "#377FE6")
        XCTAssertNil(MascotColor(paletteName: "mauve", in: data))
    }

    func testCGColorComponents() {
        let components = MascotColor.cgColor(hex: "#ff8000").components ?? []
        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(components[0], 1, accuracy: 0.001)
        XCTAssertEqual(components[1], 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components[2], 0, accuracy: 0.001)
    }
}
