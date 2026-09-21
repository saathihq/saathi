//
//  OnboardingAnswersTests.swift
//  SaathiKitTests
//
//  What someone says when a voice asks their name is not their name: it is "my name is Asha", or
//  "uh, Asha.", or "call me Ash". These pin what is kept.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingAnswersTests: XCTestCase {

    func testANameIsTakenOutOfTheSentenceItArrivedIn() {
        XCTAssertEqual(AnswerParser.name(from: "Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "my name is Asha."), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "My name's Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "I'm Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "I am Asha Rao"), "Asha Rao")
        XCTAssertEqual(AnswerParser.name(from: "call me Ash!"), "Ash")
        XCTAssertEqual(AnswerParser.name(from: "you can call me Ash"), "Ash")
        XCTAssertEqual(AnswerParser.name(from: "it's Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "uh, Asha"), "Asha")
    }

    /// Speech recognition lower-cases freely; a name is given back with its first letters raised.
    /// A name typed with its own capitals is left alone.
    func testALowercasedNameIsCapitalisedAndATypedOneIsLeftAlone() {
        XCTAssertEqual(AnswerParser.name(from: "my name is asha rao"), "Asha Rao")
        XCTAssertEqual(AnswerParser.name(from: "McKenzie"), "McKenzie")
        XCTAssertEqual(AnswerParser.name(from: "அஷா"), "அஷா", "a name in another script is kept as given")
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(AnswerParser.name(from: ""))
        XCTAssertNil(AnswerParser.name(from: "   "))
        XCTAssertNil(AnswerParser.name(from: "my name is"))
        XCTAssertNil(AnswerParser.name(from: "..."))
    }

    /// A name is a few words. A paragraph is a misheard room, not a name.
    func testAVeryLongAnswerIsNotAName() {
        XCTAssertNil(AnswerParser.name(from: "well I was thinking about what to have for lunch today and"))
    }

    func testAGoalLosesItsPreambleAndKeepsItsWords() {
        XCTAssertEqual(AnswerParser.goal(from: "I want to learn the tabla"), "the tabla")
        XCTAssertEqual(AnswerParser.goal(from: "I'd like to learn how to edit video."), "how to edit video")
        XCTAssertEqual(AnswerParser.goal(from: "I want to play with Blender"), "Blender")
        XCTAssertEqual(AnswerParser.goal(from: "spreadsheets"), "spreadsheets")
        XCTAssertNil(AnswerParser.goal(from: "  "))
    }

    func testTheThreeMannersAreTheSpecsThree() {
        XCTAssertEqual(Manner.calmAndSlow.tone, .calm);        XCTAssertEqual(Manner.calmAndSlow.pace, .slow)
        XCTAssertEqual(Manner.warmAndNormal.tone, .encouraging); XCTAssertEqual(Manner.warmAndNormal.pace, .normal)
        XCTAssertEqual(Manner.plain.tone, .neutral);           XCTAssertEqual(Manner.plain.pace, .normal)
        XCTAssertEqual(Manner.allCases.map(\.title), ["calm and slow", "warm and normal", "plain"])
    }

    func testAMannerIsHeardFromAnyOfItsWords() {
        XCTAssertEqual(Manner.parse("calm and slow"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("slow please"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("the first one"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("Warm."), .warmAndNormal)
        XCTAssertEqual(Manner.parse("normal is fine"), .warmAndNormal)
        XCTAssertEqual(Manner.parse("second"), .warmAndNormal)
        XCTAssertEqual(Manner.parse("just plain"), .plain)
        XCTAssertEqual(Manner.parse("the last one"), .plain)
        XCTAssertNil(Manner.parse("whatever you think"))
        XCTAssertNil(Manner.parse(""))
    }

    /// "Normal" is in the second choice's name and "slow" in the first's; an answer naming two
    /// different choices is not an answer.
    func testAnAnswerThatNamesTwoMannersIsNotAnAnswer() {
        XCTAssertNil(Manner.parse("calm or plain, I don't mind"))
    }

    func testALanguageIsChosenOnlyFromWhatThisMacSupports() {
        let supported = ["en-US", "en-IN", "hi-IN", "ta-IN", "ko-KR"]
        XCTAssertEqual(AnswerParser.language(from: "Hindi", supported: supported), "hi-IN")
        XCTAssertEqual(AnswerParser.language(from: "let's talk in tamil", supported: supported), "ta-IN")
        XCTAssertEqual(AnswerParser.language(from: "हिन्दी", supported: supported), "hi-IN", "its own name for itself counts")
        XCTAssertEqual(AnswerParser.language(from: "한국어", supported: supported), "ko-KR")
        XCTAssertNil(AnswerParser.language(from: "Klingon", supported: supported))
        XCTAssertNil(AnswerParser.language(from: "French", supported: supported), "a real language this Mac cannot recognise is still a no")
    }

    /// Several regions of one language: the first listed wins, so the app decides by ordering —
    /// it puts the machine's own region first.
    func testTheFirstSupportedRegionOfALanguageWins() {
        XCTAssertEqual(AnswerParser.language(from: "English", supported: ["en-IN", "en-US"]), "en-IN")
        XCTAssertEqual(AnswerParser.language(from: "English", supported: ["en-US", "en-IN"]), "en-US")
    }

    func testATagSaidOrTypedExactlyIsAccepted() {
        XCTAssertEqual(AnswerParser.language(from: "ta-IN", supported: ["en-US", "ta-IN"]), "ta-IN")
    }
}
