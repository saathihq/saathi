//
//  PointerGroundingTests.swift
//  SaathiKitTests
//
//  The words the vision model is given about the thing under the pointer. The Accessibility read
//  itself needs a real screen; everything it feeds is a value, and is checked here.
//

import XCTest
@testable import SaathiKit

final class PointerGroundingTests: XCTestCase {

    /// The case this exists for: "Play" on every row of a list, and the row's name is what tells
    /// them apart.
    func testACaptionedControlIsNamedWithItsRowAndWindow() {
        let context = PointerContext(
            appName: "Spotify", windowTitle: "Liked Songs", role: "AXButton", caption: "Play",
            containerTitles: ["Tum Hi Ho, Arijit Singh"])
        XCTAssertEqual(
            context.sentence,
            "macOS Accessibility reports that the pointer is over a button captioned \"Play\", "
                + "inside \"Tum Hi Ho, Arijit Singh\", in the Spotify window \"Liked Songs\".")
    }

    /// A row has no caption of its own; what is inside it is the answer to "this song".
    func testAnUncaptionedRowIsDescribedByWhatIsInsideIt() {
        let context = PointerContext(
            appName: "Spotify", windowTitle: nil, role: "AXRow", caption: "",
            nearbyCaptions: ["Tum Hi Ho", "Arijit Singh"])
        XCTAssertEqual(
            context.sentence,
            "macOS Accessibility reports that the pointer is over a list row containing "
                + "\"Tum Hi Ho\", \"Arijit Singh\", in Spotify.")
    }

    func testContainersReadNearestFirst() {
        let context = PointerContext(
            appName: nil, windowTitle: nil, role: "AXStaticText", caption: "Edit",
            containerTitles: ["openclicky", "Repositories"])
        XCTAssertEqual(
            context.sentence,
            "macOS Accessibility reports that the pointer is over text captioned \"Edit\", "
                + "inside \"openclicky\", inside \"Repositories\".")
    }

    /// An unknown role must not reach a sentence that may be read aloud.
    func testAnUnknownRoleIsSaidInWords() {
        XCTAssertEqual(PointerGrounding.word(forRole: "AXSplitGroup"), "an element")
        XCTAssertEqual(PointerGrounding.word(forRole: ""), "an element")
    }

    func testNothingToSayIsNotInformative() {
        let bare = PointerContext(appName: "Finder", windowTitle: "Desktop", role: "AXGroup", caption: "")
        XCTAssertFalse(bare.isInformative)
        let named = PointerContext(appName: nil, windowTitle: nil, role: "AXImage", caption: "Saathi Signing")
        XCTAssertTrue(named.isInformative)
    }

    /// Controls are not containers, the window is reported separately, the element's own caption
    /// is not repeated, and three is enough.
    func testContainerTitlesKeepOnlyTheGroupsThatNameThings() {
        let ancestors: [PointerGrounding.Ancestor] = [
            .init(role: "AXCell", caption: "Play"),
            .init(role: "AXButton", caption: "Row actions"),
            .init(role: "AXRow", caption: "Tum Hi Ho"),
            .init(role: "AXGroup", caption: ""),
            .init(role: "AXTable", caption: "Tum Hi Ho"),
            .init(role: "AXTable", caption: "Songs"),
            .init(role: "AXScrollArea", caption: "Library"),
            .init(role: "AXGroup", caption: "Main"),
            .init(role: "AXWindow", caption: "Liked Songs"),
        ]
        XCTAssertEqual(
            PointerGrounding.containerTitles(from: ancestors, elementCaption: "Play"),
            ["Tum Hi Ho", "Songs", "Library"])
    }

    /// An `AXValue` can be a whole document.
    func testCaptionsAreCollapsedAndClipped() {
        XCTAssertEqual(PointerGrounding.clipped("  two\n  lines "), "two lines")
        let long = String(repeating: "a", count: 500)
        let clipped = PointerGrounding.clipped(long)
        XCTAssertEqual(clipped.count, PointerGrounding.maxCaptionLength + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }
}
