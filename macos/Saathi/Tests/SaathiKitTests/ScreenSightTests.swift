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

    /// "What is the meaning of this line?" with "reconnects" highlighted was answered about the
    /// red triangle under the pointer. The selection is handed over and named as what "this" means.
    func testASelectionIsWhatThisMeans() {
        let prompt = ScreenSight.systemPrompt(question: "What is the meaning of this line?", selection: "reconnects")
        XCTAssertTrue(prompt.contains("«reconnects»"), prompt)
        XCTAssertTrue(prompt.contains("the selection is almost certainly what they mean"))
        XCTAssertFalse(ScreenSight.systemPrompt(question: "q").contains("selected (highlighted)"), "no selection, no claim of one")
    }

    func testASelectionIsTidiedAndCapped() {
        XCTAssertEqual(PointerGrounding.selection("  two\n  words "), "two words")
        XCTAssertNil(PointerGrounding.selection(" \n "))
        XCTAssertEqual(PointerGrounding.selection(String(repeating: "a", count: 700))?.count, 601)
    }


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

    /// The eye is asked where the thing is, in the first picture's own pixels, and told that
    /// picture's size — an eye that is not told the size guesses one.
    func testThePromptAsksWhereTheThingIsInThePicturesOwnPixels() {
        let prompt = ScreenSight.systemPrompt(question: "which button", pixelSize: CGSize(width: 2880, height: 1800))
        XCTAssertTrue(prompt.contains("2880×1800 pixels"), prompt)
        XCTAssertTrue(prompt.contains("[POINT:x,y:visible text]"), prompt)
        XCTAssertTrue(prompt.contains("[POINT:none]"), prompt)
        XCTAssertTrue(prompt.hasSuffix("which button"))
        XCTAssertFalse(ScreenSight.systemPrompt(question: "q").contains("POINT"), "not asked for when there is no picture to point into")
    }

    func testThePromptSaysWhatTheSecondPictureIs() {
        let prompt = ScreenSight.systemPrompt(question: "how do I play this song")
        XCTAssertTrue(prompt.contains("close-up"), prompt)
        XCTAssertTrue(prompt.contains("pointer"), prompt)
        XCTAssertTrue(prompt.hasSuffix("how do I play this song"))
    }

    /// Both lanes hand a failed look back to the model as words it can repeat: "I need Screen
    /// Recording permission" is a useful thing to be told, and silence is not. With no key to look
    /// with, nothing is captured at all.
    func testAFailedLookIsASentenceForTheModelToRepeat() async {
        let look = await ScreenSight(configuration: .init(provider: .local)).answer("what is this?")
        XCTAssertEqual(look.answer, "could not look: seeing the screen needs an OpenAI or Anthropic key. Add one in Setup.")
        XCTAssertNil(look.target)
    }

    func testTheEyeIsAnthropicFirstThenOpenAI() {
        XCTAssertEqual(ScreenSight.eye(for: .init(provider: .openai, openaiKey: "sk-o")), .openai(model: "gpt-4o-mini"))
        XCTAssertEqual(
            ScreenSight.eye(for: .init(provider: .openai, openaiKey: "sk-o", anthropicKey: "sk-a")),
            .anthropic(model: "claude-haiku-4-5-20251001"))
        XCTAssertNil(ScreenSight.eye(for: .init(provider: .local)))
    }

    /// A shared key is the named provider's and nobody else's. A Sarvam key is not something to
    /// show Anthropic, with a picture of the screen attached — which is what asking for a look did.
    func testALegacyKeyIsOnlyAnEyeForTheProviderItWasWrittenFor() {
        XCTAssertNil(ScreenSight.eye(for: .init(provider: .sarvam, apiKey: "sk-sarvam")))
        XCTAssertNil(ScreenSight.eye(for: .init(apiKey: "sk-whose")))
        XCTAssertEqual(ScreenSight.eye(for: .init(provider: .openai, apiKey: "sk-o")), .openai(model: "gpt-4o-mini"))
        XCTAssertEqual(
            ScreenSight.eye(for: .init(provider: .anthropic, apiKey: "sk-a")),
            .anthropic(model: "claude-haiku-4-5-20251001"))
    }

    /// What Accessibility says is under the pointer settles which thing "this" is; without it the
    /// prompt is exactly what it was.
    func testThePromptCarriesWhatAccessibilitySaysIsUnderThePointer() {
        let context = PointerContext(
            appName: "Spotify", windowTitle: "Liked Songs", role: "AXRow", caption: "",
            nearbyCaptions: ["Tum Hi Ho", "Arijit Singh"])
        let grounded = ScreenSight.systemPrompt(question: "how do I play this song", grounding: context)
        XCTAssertTrue(grounded.contains(context.sentence))
        XCTAssertTrue(grounded.contains("trust it for which"))
        let plain = ScreenSight.systemPrompt(question: "how do I play this song")
        XCTAssertFalse(plain.contains("Accessibility"))
    }
}
