//
//  NotchGeometryTests.swift
//  SaathiShellTests
//

import XCTest
@testable import SaathiShell

final class NotchGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testOnANotchedScreenThePanelCoversTheNotchAndALipBelowIt() {
        // A 14-inch MacBook Pro: 32 pt safe area, the notch between the two auxiliary areas.
        let left = CGRect(x: 0, y: 950, width: 656, height: 32)
        let right = CGRect(x: 856, y: 950, width: 656, height: 32)
        let frame = NotchGeometry.collapsedFrame(screen: screen, safeAreaTop: 32, leftAuxiliary: left, rightAuxiliary: right)
        XCTAssertEqual(frame.minX, 656)
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.maxY, 982, "flush with the top")
        XCTAssertEqual(frame.height, 32 + NotchGeometry.lip)
    }

    func testWithoutANotchItIsAPillUnderTheMenuBar() {
        let frame = NotchGeometry.collapsedFrame(screen: screen, safeAreaTop: 0, leftAuxiliary: nil, rightAuxiliary: nil)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.width, NotchGeometry.pillWidth)
        XCTAssertEqual(frame.height, NotchGeometry.pillHeight)
        XCTAssertEqual(frame.maxY, 982 - NotchGeometry.menuBarHeight)
    }

    func testExpandingKeepsTheTopEdgeAndGrowsDownAndOut() {
        let collapsed = CGRect(x: 656, y: 922, width: 200, height: 60)
        let expanded = NotchGeometry.expandedFrame(collapsed: collapsed, height: 180, minWidth: 320)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
        XCTAssertEqual(expanded.height, 180)
        XCTAssertEqual(expanded.width, 320)
        XCTAssertEqual(expanded.midX, collapsed.midX)
    }
}
