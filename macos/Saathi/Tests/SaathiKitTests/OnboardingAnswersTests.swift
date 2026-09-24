//
//  OnboardingAnswersTests.swift
//  SaathiKitTests
//
//  What someone says when a voice asks their name is not their name: it is "my name is Asha", or
//  "uh, Asha.", or "call me Ash". These pin what is kept.
//

import AVFoundation
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

final class OnboardingLanguagesTests: XCTestCase {

    func testOneEntryPerLanguageTheMachinesRegionWinsAndItsLanguageLeads() {
        let entries = OnboardingLanguages.entries(
            from: ["en-US", "en-GB", "en-IN", "hi-IN", "ta-IN", "ko-KR", "fr-FR", "fr-CA"], machine: "en-IN")
        XCTAssertEqual(entries.first, .init(tag: "en-IN", name: "English"))
        XCTAssertEqual(entries.map(\.name), ["English", "French", "Hindi", "Korean", "Tamil"])
        XCTAssertEqual(entries.first { $0.name == "French" }?.tag, "fr-CA", "no machine region: the first alphabetically")
    }

    func testAMachineWhoseLanguageIsNotSupportedLeadsWithNothingSpecial() {
        let entries = OnboardingLanguages.entries(from: ["en-US", "hi-IN"], machine: "ml-IN")
        XCTAssertEqual(entries.map(\.tag), ["en-US", "hi-IN"])
    }

    func testNoRecogniserAtAllStillOffersSomething() {
        XCTAssertEqual(OnboardingLanguages.entries(from: [], machine: "en-US"), [.init(tag: "en-US", name: "English")])
    }
}


final class InputLevelTests: XCTestCase {

    /// Decibels, not raw amplitude: on a linear scale ordinary speech sits in the bottom tenth and
    /// the bars barely move, which reads as "it cannot hear me".
    func testOrdinarySpeechMovesTheBarsAndSilenceDoesNot() {
        XCTAssertEqual(InputLevel.normalised(rms: 0), 0)
        XCTAssertEqual(InputLevel.normalised(rms: 0.001), 0, "room noise, -60 dB")
        XCTAssertGreaterThan(InputLevel.normalised(rms: 0.05), 0.5, "speech at arm's length, about -26 dB")
        XCTAssertEqual(InputLevel.normalised(rms: 0.5), 1, "close and loud is simply full")
        XCTAssertEqual(InputLevel.normalised(rms: .nan), 0)
        XCTAssertEqual(InputLevel.normalised(rms: -1), 0)
    }

    func testTheLevelOfABufferIsItsFirstChannelsRMS() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        XCTAssertEqual(InputLevel.level(of: buffer), 0, "silence")
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<480 { channel[index] = index.isMultiple(of: 2) ? 0.1 : -0.1 }
        XCTAssertEqual(InputLevel.level(of: buffer), InputLevel.normalised(rms: 0.1), accuracy: 0.0001)
        buffer.frameLength = 0
        XCTAssertEqual(InputLevel.level(of: buffer), 0)
    }
}

final class LearnerProfileTests: XCTestCase {

    /// An install that never ran first run gets exactly the prompt it had before.
    func testNothingLearnedMeansNothingAdded() {
        XCTAssertEqual(LearnerProfile.paragraph(for: SaathiConfiguration()), "")
        XCTAssertEqual(
            RealtimeVoiceSession.instructions(for: SaathiConfiguration(language: "en")),
            RealtimeVoiceSession.instructions(language: "en"))
    }

    func testWhatFirstRunLearnedReachesTheModel() {
        let configuration = SaathiConfiguration(
            language: "ta", name: "Asha", tone: .calm, pace: .slow, firstGoal: "the tabla")
        let prompt = RealtimeVoiceSession.instructions(for: configuration)
        XCTAssertTrue(prompt.hasPrefix(RealtimeVoiceSession.instructions(language: "ta")), "added to, not replaced")
        XCTAssertTrue(prompt.contains("called Asha"))
        XCTAssertTrue(prompt.contains("\"the tabla\""))
        XCTAssertTrue(prompt.contains("calm"))
        XCTAssertTrue(prompt.contains("Go slowly"))
    }

    func testEachMannerSaysSomethingDifferentAndNormalPaceSaysNothing() {
        XCTAssertNil(LearnerProfile.manner(tone: nil, pace: nil))
        XCTAssertNil(LearnerProfile.manner(tone: nil, pace: .normal))
        let calm = LearnerProfile.manner(tone: .calm, pace: .slow)
        let warm = LearnerProfile.manner(tone: .encouraging, pace: .normal)
        let plain = LearnerProfile.manner(tone: .neutral, pace: .normal)
        XCTAssertEqual(Set([calm, warm, plain]).count, 3)
        XCTAssertFalse(warm?.contains("slowly") ?? true)
    }

    /// A transcript can be a paragraph, and it is the learner's text going into a system prompt:
    /// one line, no quotes to close the sentence it sits in, and clipped.
    func testTheLearnersWordsAreFlattenedAndClipped() {
        XCTAssertEqual(LearnerProfile.tidied("  the\n tabla  "), "the tabla")
        XCTAssertEqual(LearnerProfile.tidied("say \"hi\""), "say 'hi'")
        XCTAssertNil(LearnerProfile.tidied("   "))
        XCTAssertNil(LearnerProfile.tidied(nil))
        let long = LearnerProfile.tidied(String(repeating: "a", count: 900))
        XCTAssertEqual(long?.count, LearnerProfile.maxFieldLength + 1)
    }
}
