//
//  ScreenSightTests.swift
//  SaathiKitTests
//
//  What is captured when Saathi looks, checked without a screen: the regions are numbers.
//

import CoreGraphics
import XCTest
@testable import SaathiKit

final class ScreenSightTests: XCTestCase {

    /// "How do I play this song?" is a question about the row under the pointer. The whole display
    /// alone had the vision model answering about the song that happened to be playing; a close-up
    /// with the pointer at its centre had it name the row that was pointed at.
    func testTheCloseUpIsCentredOnThePointer() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let regions = ScreenCapture.regions(display: display, pointer: CGPoint(x: 700, y: 500))
        XCTAssertEqual(regions.display, display)
        XCTAssertEqual(regions.closeUp.size, ScreenCapture.closeUpSize)
        XCTAssertEqual(regions.closeUp.midX, 700, accuracy: 0.5)
        XCTAssertEqual(regions.closeUp.midY, 500, accuracy: 0.5)
    }

    /// The close-up stays inside the display near an edge, so it is still a full-size picture and
    /// the pointer is still in it — just not in the middle.
    func testTheCloseUpStaysInsideTheDisplayNearAnEdge() {
        let display = CGRect(x: -173, y: -1080, width: 1920, height: 1080)   // a display above the main one
        let regions = ScreenCapture.regions(display: display, pointer: CGPoint(x: -100, y: -1070))
        XCTAssertEqual(regions.display, display)
        XCTAssertEqual(regions.closeUp.size, ScreenCapture.closeUpSize)
        XCTAssertTrue(display.contains(regions.closeUp), "\(regions.closeUp) leaves \(display)")
        XCTAssertTrue(regions.closeUp.contains(CGPoint(x: -100, y: -1070)))
    }

    /// The pointer's own display is the one captured. A second monitor's contents are never sent
    /// along with it, and a question about something on the second monitor is not answered from
    /// the first.
    func testTheDisplayCapturedIsThePointersOwn() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let regions = ScreenCapture.regions(display: external, pointer: CGPoint(x: 2000, y: 300))
        XCTAssertEqual(regions.display, external)
    }

    func testThePromptSaysWhatTheSecondPictureIs() {
        let prompt = ScreenSight.systemPrompt(question: "how do I play this song")
        XCTAssertTrue(prompt.contains("close-up"), prompt)
        XCTAssertTrue(prompt.contains("pointer"), prompt)
        XCTAssertTrue(prompt.hasSuffix("how do I play this song"))
    }

    func testTheEyeIsAnthropicFirstThenOpenAI() {
        XCTAssertEqual(ScreenSight.eye(for: .init(provider: .openai, openaiKey: "sk-o")), .openai(model: "gpt-4o-mini"))
        XCTAssertEqual(
            ScreenSight.eye(for: .init(provider: .openai, openaiKey: "sk-o", anthropicKey: "sk-a")),
            .anthropic(model: "claude-haiku-4-5-20251001"))
        XCTAssertNil(ScreenSight.eye(for: .init(provider: .local)))
    }
}
