//
//  ScreenTargetTests.swift
//  SaathiKitTests
//
//  Where a look's answer points, and how the spot is settled: the eye's tag read out of its
//  answer, the frame's pixels turned into screen points, text on the frame snapped to, and the
//  front window's controls told apart. Pure, except for one real pass of the text recogniser over
//  a picture drawn here.
//

import AppKit
import CoreGraphics
import XCTest
@testable import SaathiKit

final class ScreenTargetTests: XCTestCase {

    private let frame = CGSize(width: 2880, height: 1800)   // a Retina display's frame, in pixels

    // MARK: the eye's tag

    /// The eye ends its answer with where the thing is. The tag is for Saathi, not for the ear:
    /// it comes out of the answer before the answer is spoken.
    func testTheTagIsReadOutOfTheAnswerAndTheAnswerIsLeftClean() {
        let read = ScreenSight.read(
            "The green button at the top left of the window makes it full screen. [POINT:118,42:]",
            pixelSize: frame)
        XCTAssertEqual(read.answer, "The green button at the top left of the window makes it full screen.")
        XCTAssertEqual(read.pixel, CGPoint(x: 118, y: 42))
        XCTAssertNil(read.visibleText, "an icon shows no text")

        let link = ScreenSight.read("Click the arXiv link under the title.\n[POINT: 640 , 912 : arXiv ]", pixelSize: frame)
        XCTAssertEqual(link.answer, "Click the arXiv link under the title.")
        XCTAssertEqual(link.pixel, CGPoint(x: 640, y: 912))
        XCTAssertEqual(link.visibleText, "arXiv")
    }

    func testNoTagOrNoneIsAnAnswerWithNowhereToPoint() {
        for reply in ["It is not on the screen. [POINT:none]", "It is not on the screen.", "[POINT:none] Nothing here."] {
            let read = ScreenSight.read(reply, pixelSize: frame)
            XCTAssertNil(read.pixel, reply)
            XCTAssertFalse(read.answer.contains("POINT"), read.answer)
        }
        XCTAssertEqual(ScreenSight.read("[POINT:none] Nothing here.", pixelSize: frame).answer, "Nothing here.")
    }

    /// A point outside the picture is the eye being wrong, not a place to send the buddy.
    func testAPointOffThePictureIsIgnored() {
        XCTAssertNil(ScreenSight.read("Here. [POINT:4000,10:]", pixelSize: frame).pixel)
        XCTAssertNil(ScreenSight.read("Here. [POINT:10,1801:]", pixelSize: frame).pixel)
        XCTAssertEqual(ScreenSight.read("Here. [POINT:2880,1800:]", pixelSize: frame).pixel, CGPoint(x: 2880, y: 1800))
    }

    // MARK: pixels and points

    /// The frame is the pointer's display at its own scale. A pixel in it is a point on that
    /// display, and the display may not be the main one, nor start at the origin.
    func testAPixelOfTheFrameIsAPointOnTheDisplayItWasTakenFrom() {
        let external = ScreenCapture.Geometry(
            region: CGRect(x: 1512, y: -200, width: 1920, height: 1080), pixelSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(external.point(ofPixel: CGPoint(x: 10, y: 20)), CGPoint(x: 1522, y: -180))

        let retina = ScreenCapture.Geometry(
            region: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(retina.point(ofPixel: CGPoint(x: 236, y: 84)), CGPoint(x: 118, y: 42))
        XCTAssertEqual(retina.rect(ofPixels: CGRect(x: 200, y: 100, width: 400, height: 50)), CGRect(x: 100, y: 50, width: 200, height: 25))
    }

    // MARK: text on the frame

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 60) -> ScreenTextLine {
        ScreenTextLine(text: text, box: CGRect(x: x, y: y, width: width, height: 14))
    }

    /// The eye is reliable about *which* thing it means and loose about its pixels — OpenClicky
    /// measured a link put 130 px too high. The text it names has an exact box on the frame.
    func testThePointIsSnappedToTheTextTheEyeNamedNearestToIt() {
        let lines = [line("Paper", x: 100, y: 100), line("Code", x: 100, y: 130), line("Paper", x: 100, y: 700)]
        let match = ScreenTextLocator.locate("paper", near: CGPoint(x: 140, y: 150), in: lines, maxDistance: 300, ambiguityMargin: 50)
        XCTAssertEqual(match?.center, CGPoint(x: 130, y: 107))
        XCTAssertEqual(match?.text, "Paper")
    }

    func testTextIsFoundInsideALongerLineAndPlacedWithinIt() {
        let lines = [ScreenTextLine(text: "Open the Paper link now", box: CGRect(x: 0, y: 0, width: 230, height: 10))]
        let match = ScreenTextLocator.locate("Paper", near: .zero, in: lines, maxDistance: 300, ambiguityMargin: 50)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.center.x ?? 0, 115, accuracy: 20, "about where \"Paper\" sits in the line")
    }

    /// "Edit" on every row of a list: two matches closer together than the eye's own error cannot
    /// be told apart by distance, so nothing is snapped to rather than the wrong one.
    func testTwoMatchesTheEyeCouldNotTellApartAreNotGuessedBetween() {
        let lines = [line("Edit", x: 500, y: 100), line("Edit", x: 500, y: 124)]
        XCTAssertNil(ScreenTextLocator.locate("Edit", near: CGPoint(x: 520, y: 110), in: lines, maxDistance: 300, ambiguityMargin: 50))
        XCTAssertNotNil(
            ScreenTextLocator.locate("Edit", near: CGPoint(x: 520, y: 110), in: lines, maxDistance: 300, ambiguityMargin: 10),
            "with a small enough margin the nearer one wins")
    }

    func testGenericWordsFarAwayTextAndNearMissesAreNotSnappedTo() {
        let lines = [line("Button", x: 10, y: 10), line("Export", x: 10, y: 40), line("Exports", x: 10, y: 900)]
        XCTAssertNil(ScreenTextLocator.locate("button", near: .zero, in: lines, maxDistance: 300, ambiguityMargin: 50), "a word that describes a control, not one that names it")
        XCTAssertNil(ScreenTextLocator.locate("Export", near: CGPoint(x: 10, y: 2000), in: lines, maxDistance: 300, ambiguityMargin: 50), "too far from where the eye put it")
        XCTAssertNil(ScreenTextLocator.locate("Expert", near: .zero, in: lines, maxDistance: 300, ambiguityMargin: 50), "exact matches only: a near miss is as likely another element")
        XCTAssertEqual(ScreenTextLocator.locate("the Export button", near: .zero, in: lines, maxDistance: 300, ambiguityMargin: 50)?.text, "Export", "the distinctive word of a longer hint")
    }

    /// One real pass of the recogniser, over a picture drawn here: the text it reads has a box
    /// where the text was drawn. No screen is captured.
    func testTheRecogniserReadsTextWhereItWasDrawn() async throws {
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
            ("Export" as NSString).draw(at: CGPoint(x: 400, y: 250), withAttributes: attributes)
            ("Settings" as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: attributes)
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let geometry = ScreenCapture.Geometry(region: CGRect(x: 0, y: 0, width: 640, height: 360), pixelSize: size)
        let lines = try await ScreenTextRecognizer.recognize(png: png, geometry: geometry)
        let export = try XCTUnwrap(lines.first { $0.text.lowercased().contains("export") }, "\(lines.map(\.text))")
        XCTAssertEqual(export.box.midX, 435, accuracy: 25)
        XCTAssertEqual(export.box.midY, 263, accuracy: 20)
        XCTAssertTrue(lines.contains { $0.text.lowercased().contains("settings") }, "\(lines.map(\.text))")
    }

    // MARK: the front window's controls

    private func control(_ role: String, _ title: String, in containers: [String] = [], at x: CGFloat, _ y: CGFloat) -> AccessibleElement {
        AccessibleElement(role: role, title: title, containerTitles: containers, center: CGPoint(x: x, y: y))
    }

    /// Accessibility knows what the pixels cannot: which row a repeated "Edit" sits in.
    func testARepeatedCaptionIsToldApartByTheRowTheRequestNames() {
        let controls = [
            control("AXButton", "Edit", in: ["saathi"], at: 500, 100),
            control("AXButton", "Edit", in: ["openclicky"], at: 500, 124),
        ]
        let match = AccessibleElementLocator.bestMatch(
            hint: "Edit", userRequest: "edit the openclicky one", near: CGPoint(x: 500, y: 100),
            in: controls, maxDistance: 300, ambiguityMargin: 50)
        XCTAssertEqual(match?.center, CGPoint(x: 500, y: 124), "the row named in the request, not the nearer one")
    }

    func testAControlBeatsALabelWithTheSameCaptionAndAnAmbiguousPairIsLeftAlone() {
        let controls = [
            control("AXStaticText", "Export", at: 300, 200),
            control("AXButton", "Export", at: 300, 230),
        ]
        XCTAssertEqual(
            AccessibleElementLocator.bestMatch(hint: "Export", userRequest: nil, near: CGPoint(x: 300, y: 200), in: controls, maxDistance: 300, ambiguityMargin: 50)?.role,
            "AXButton")

        let twins = [control("AXButton", "Edit", at: 500, 100), control("AXButton", "Edit", at: 500, 124)]
        XCTAssertNil(AccessibleElementLocator.bestMatch(hint: "Edit", userRequest: "edit it", near: CGPoint(x: 500, y: 110), in: twins, maxDistance: 300, ambiguityMargin: 50))
    }

    // MARK: settling the spot

    /// The order: the text the eye named, on the frame; then the front window's controls; then
    /// the eye's own point. Each says how it was settled, for the log.
    func testTheSpotIsSettledByTextThenByAccessibilityThenByTheEye() {
        let eye = CGPoint(x: 120, y: 150)
        let lines = [line("Paper", x: 100, y: 100)]
        let controls = [control("AXLink", "Paper", in: ["Inter-brain synchrony"], at: 130, 107)]

        let byText = ScreenSight.settle(eye: eye, visibleText: "Paper", question: "where is the paper", lines: lines, controls: controls, radius: 300, margin: 50)
        XCTAssertEqual(byText.point, CGPoint(x: 130, y: 107))
        XCTAssertTrue(byText.how.hasPrefix("the text"), byText.how)

        let byAccessibility = ScreenSight.settle(eye: eye, visibleText: "Paper", question: "where is the paper", lines: [], controls: controls, radius: 300, margin: 50)
        XCTAssertEqual(byAccessibility.point, CGPoint(x: 130, y: 107))
        XCTAssertTrue(byAccessibility.how.hasPrefix("Accessibility"), byAccessibility.how)

        let byEye = ScreenSight.settle(eye: eye, visibleText: nil, question: "which button", lines: lines, controls: controls, radius: 300, margin: 50)
        XCTAssertEqual(byEye.point, eye)
        XCTAssertTrue(byEye.how.hasPrefix("the eye"), byEye.how)
        XCTAssertNil(byEye.visibleText)
    }
}
