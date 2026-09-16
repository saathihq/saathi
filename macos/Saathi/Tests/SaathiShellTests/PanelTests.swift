//
//  PanelTests.swift
//  SaathiShellTests
//
//  Panels are checked by eye in the running app; these only pin what they expose and that they
//  can be built and driven without a run loop.
//

import AppKit
import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

@MainActor
final class PanelTests: XCTestCase {

    private func data() throws -> MascotData { try MascotData.load() }
    private let blue = MascotColor(hex: "#377FE6")

    func testTheCompanionIsClickThroughFloatingAndOnEverySpace() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.frame.size, NSSize(width: CompanionPanel.side, height: CompanionPanel.side))
        XCTAssertFalse(panel.isShowing)
    }

    func testTheCompanionFollowsAPointerAndLooksAtIt() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        let before = panel.frame.origin
        panel.step(pointer: CGPoint(x: before.x + 400, y: before.y + 300), dt: 10)
        XCTAssertGreaterThan(panel.frame.origin.x, before.x)
        XCTAssertGreaterThan(panel.frame.origin.y, before.y)
    }

    func testTheCompanionShowsTheStateOnItsFaceAndForVoiceOver() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        panel.setState(.listening)
        XCTAssertEqual(panel.mascot.expression, .listening)
        XCTAssertEqual(panel.mascot.accessibilityLabel(), "Listening")
    }

    func testTheNotchPanelShowsTheWordAndTheFace() throws {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let panel = NotchPanel(data: try data(), color: blue, screen: screen)
        panel.setState(.thinking)
        XCTAssertEqual(panel.word, "Thinking")
        XCTAssertEqual(panel.mascot.expression, .thinking)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY - (screen.safeAreaInsets.top > 0 ? 0 : NotchGeometry.menuBarHeight), accuracy: 0.5)
    }
}
