//
//  NotchGeometryTests.swift
//  SaathiShellTests
//
//  The numbers are a 14-inch MacBook Pro's, measured: a 1512 × 982 frame, a 32 pt safe area and
//  two 656 pt auxiliary areas either side of the notch.
//

import XCTest
@testable import SaathiShell

final class NotchGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func notched() -> NotchGeometry {
        NotchGeometry.forScreen(
            frame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            leftAuxiliary: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightAuxiliary: CGRect(x: 856, y: 950, width: 656, height: 32)
        )
    }

    private func virtual(visibleTop: CGFloat) -> NotchGeometry {
        NotchGeometry.forScreen(
            frame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: visibleTop),
            safeAreaTop: 0,
            leftAuxiliary: nil,
            rightAuxiliary: nil
        )
    }

    func testOnANotchedScreenTheCollapsedIslandIsExactlyTheNotch() {
        let geometry = notched()
        XCTAssertTrue(geometry.hasHardwareNotch)
        XCTAssertEqual(geometry.notchWidth, 200)
        XCTAssertEqual(geometry.notchHeight, 32)
        XCTAssertEqual(geometry.notchRect, CGRect(x: 656, y: 950, width: 200, height: 32))
    }

    func testTheOpenIslandHangsFromTheTopEdgeCentredOnTheNotch() {
        let geometry = notched()
        let island = geometry.islandRect(width: 320, contentHeight: 96)
        XCTAssertEqual(island, CGRect(x: 596, y: 854, width: 320, height: 128))
        XCTAssertEqual(island.maxY, 982, "flush with the top of the screen")
        XCTAssertEqual(island.midX, geometry.notchRect.midX)
    }

    func testWithoutANotchItIsAVirtualOneTheHeightOfTheMenuBarBand() {
        let geometry = virtual(visibleTop: 958)
        XCTAssertFalse(geometry.hasHardwareNotch)
        XCTAssertEqual(geometry.notchWidth, NotchGeometry.virtualNotchWidth)
        XCTAssertEqual(geometry.notchRect, CGRect(x: 661, y: 958, width: 190, height: 24))
    }

    func testTheHandleSitsJustInsideTheTopEdgeWhereTheNotchWouldBe() {
        let geometry = virtual(visibleTop: 958)
        let handle = geometry.handleRect
        XCTAssertEqual(handle.midX, 756)
        XCTAssertEqual(handle.maxY, 979, "3 pt down from the screen's top edge")
        XCTAssertEqual(handle.size, NotchGeometry.handleSize)
    }

    /// A hidden menu bar (or full screen) leaves no band to tuck the handle into, and a handle
    /// over somebody's content explains nothing.
    func testWithNoMenuBarBandThereIsNoHandle() {
        XCTAssertFalse(virtual(visibleTop: 982).showsHandle, "no band, no handle")
        XCTAssertTrue(virtual(visibleTop: 958).showsHandle, "a 24 pt band has room for it")
        XCTAssertFalse(notched().showsHandle, "a hardware notch needs no marker")
    }

    func testAuxiliaryAreasThatDoNotStraddleANotchAreNotOne() {
        // A display that reports a safe area but no gap between the two areas has no notch to hang
        // anything in; the virtual one is the honest answer.
        let geometry = NotchGeometry.forScreen(
            frame: screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958),
            safeAreaTop: 32,
            leftAuxiliary: CGRect(x: 0, y: 950, width: 756, height: 32),
            rightAuxiliary: CGRect(x: 0, y: 950, width: 756, height: 32)
        )
        XCTAssertFalse(geometry.hasHardwareNotch)
        XCTAssertEqual(geometry.notchWidth, NotchGeometry.virtualNotchWidth)
        XCTAssertEqual(geometry.notchHeight, 24)
    }

    func testADisplayWithNoMenuBarBandHasAZeroHeightNotch() {
        let geometry = virtual(visibleTop: 982)
        XCTAssertEqual(geometry.notchHeight, 0)
        XCTAssertEqual(geometry.notchRect.maxY, 982)
    }

    func testTheHoverRectGrowsSidewaysAndDownButNeverAboveTheScreen() {
        let geometry = notched()
        let hover = NotchGeometry.hoverRect(
            around: geometry.notchRect,
            margin: NotchGeometry.hoverMarginCollapsed,
            screenFrame: screen
        )
        XCTAssertEqual(hover.minX, 650, "6 pt to the left")
        XCTAssertEqual(hover.maxX, 862, "6 pt to the right")
        XCTAssertEqual(hover.minY, 944, "6 pt below")
        XCTAssertEqual(hover.maxY, 983, "the screen's top edge, plus a point of slack")
        XCTAssertTrue(
            hover.contains(CGPoint(x: 756, y: 982)),
            "a pointer shoved against the very top of the screen is reaching for the island"
        )
    }

    func testTheOpenIslandGetsTheLooserHoverMargin() {
        let geometry = notched()
        let island = geometry.islandRect(width: 320, contentHeight: 96)
        let hover = NotchGeometry.hoverRect(
            around: island,
            margin: NotchGeometry.hoverMarginOpen,
            screenFrame: screen
        )
        XCTAssertEqual(hover.width, island.width + 28)
        XCTAssertEqual(hover.minY, island.minY - 14)
        XCTAssertEqual(hover.maxY, 983)
        XCTAssertGreaterThan(NotchGeometry.hoverMarginOpen, NotchGeometry.hoverMarginCollapsed)
    }
}
