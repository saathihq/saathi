//
//  SpeakerTests.swift
//  SaathiKitTests
//
//  AVSpeechSynthesizer reports `isSpeaking == false` for tens of milliseconds after `speak()`,
//  so a poll on that flag returns before any audio and a CLI exits silent. These pin the
//  delegate-driven wait that replaced it.
//

import AVFoundation
import Foundation
import os
import XCTest
import SaathiContract
@testable import SaathiKit

final class UtteranceWaiterTests: XCTestCase {

    private let synthesizer = AVSpeechSynthesizer()
    private let utterance = AVSpeechUtterance(string: "x")

    func testWaitDoesNotReturnUntilTheDelegateReportsAFinish() async {
        let waiter = UtteranceWaiter()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let waiting = Task {
            await waiter.wait()
            finished.withLock { $0 = true }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished.withLock { $0 }, "wait() returned before the delegate said anything")

        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiting.value
        XCTAssertTrue(finished.withLock { $0 })
    }

    func testAFinishThatArrivesBeforeWaitDoesNotHang() async {
        let waiter = UtteranceWaiter()
        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiter.wait()   // would hang forever if the early finish were lost
    }

    func testACancelAlsoEndsTheWait() async {
        let waiter = UtteranceWaiter()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let waiting = Task {
            await waiter.wait()
            finished.withLock { $0 = true }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(finished.withLock { $0 }, "wait() returned before the delegate said anything")

        waiter.speechSynthesizer(synthesizer, didCancel: utterance)
        await waiting.value
        XCTAssertTrue(finished.withLock { $0 })
    }
}

final class SystemSpeakerTests: XCTestCase {

    /// Not a test of audio (there is none here): it exercises the serialisation seam in `speak` —
    /// two overlapping calls each await whatever is already in flight before starting their own,
    /// so neither one strands. An empty utterance finishes fast, so both calls should return
    /// well within the timeout even run back to back.
    ///
    /// Opt-in: even an empty utterance opens the system's audio output, and a test run in the
    /// background took the sound out of a game that was being played at the time. Run it with
    /// `SAATHI_AUDIO_TESTS=1 swift test` when the speaker itself is what changed.
    func testOverlappingSpeakCallsDoNotStrandTheFirst() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAATHI_AUDIO_TESTS"] == "1",
            "touches the real audio output; set SAATHI_AUDIO_TESTS=1 to run it")
        let speaker = SystemSpeaker()
        let start = DispatchTime.now()
        async let first: Void = speaker.speak("", tone: .neutral)
        async let second: Void = speaker.speak("", tone: .neutral)
        _ = await (first, second)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertLessThan(elapsed, 5, "overlapping speak calls did not both return within 5 s")
    }
}

final class ObservedSpeakerTests: XCTestCase {

    func testItReportsStartAndStopAroundTheInnerSpeaker() async {
        let inner = RecordingSpeaker()
        let events = OSAllocatedUnfairLock(initialState: [Bool]())
        let speaker = ObservedSpeaker(inner) { speaking in events.withLock { $0.append(speaking) } }
        await speaker.speak("hello", tone: .calm)
        XCTAssertEqual(events.withLock { $0 }, [true, false])
        XCTAssertEqual(inner.lines, [RecordingSpeaker.Line(text: "hello", tone: .calm)])
    }

    /// Quitting cuts speech off through the observer, whatever is underneath it.
    func testStopPassesThroughAndIsHarmlessOnASpeakerThatCannotBeStopped() async throws {
        let speaker = ObservedSpeaker(RecordingSpeaker()) { _ in }
        speaker.stop()   // a recording speaker has nothing to cut off
        await speaker.speak("still works", tone: .neutral)

        let system: any Speaker = SystemSpeaker()
        let stoppable = try XCTUnwrap(system as? StoppableSpeaker, "the system speaker can be cut off")
        stoppable.stop()   // nothing is being said; the synthesizer shrugs
    }

    func testStopIsReportedEvenIfTheInnerSpeakerIsCancelled() async {
        struct Slow: Speaker {
            func speak(_ text: String, tone: Tone) async { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        let events = OSAllocatedUnfairLock(initialState: [Bool]())
        let speaker = ObservedSpeaker(Slow()) { speaking in events.withLock { $0.append(speaking) } }
        let task = Task { await speaker.speak("x", tone: .neutral) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(events.withLock { $0 }, [true, false])
    }
}

final class SpeechSettingsTests: XCTestCase {

    private let installed = ["en-US", "en-GB", "en-IN", "hi-IN", "ta-IN", "ko-KR"]

    /// A Tamil sentence read by an English synthesiser is noise.
    func testTheVoiceFollowsTheLanguageSaathiWasToldToSpeak() {
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "ta-IN", available: installed), "ta-IN")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "ta", available: installed), "ta-IN", "a bare language finds its region")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "EN-in", available: installed), "en-IN")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "en-AU", available: installed), "en-US", "no such region: the language's usual voice")
    }

    func testNoVoiceForTheLanguageFallsBackToEnglishRatherThanSilence() {
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "ml-IN", available: installed), "en-US")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: nil, available: installed), "en-US")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "  ", available: installed), "en-US")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "e", available: installed), "en-US", "a prefix of a code is not the code")
    }

    /// "en" is what an unconfigured install resolves to. Sorted-first made that Australian.
    func testABareLanguageTakesTheLearnersOwnRegionThenTheUsualOneNeverTheAlphabeticalOne() {
        let macOS = ["en-AU", "en-GB", "en-IE", "en-IN", "en-US", "en-ZA", "pt-BR", "pt-PT", "ta-IN"]
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "en", available: macOS), "en-US")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "en", available: macOS, preferred: ["hi-IN", "en-IN"]), "en-IN")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "pt", available: macOS), "pt-PT")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "en-NZ", available: macOS, preferred: ["en-NZ"]), "en-US",
                       "their region has no voice: the usual one, not the first in the alphabet")
        XCTAssertEqual(SpeechSettings.voiceLanguage(wanted: "en", available: ["en-AU", "en-ZA"]), "en-AU", "only then, any")
    }

    /// Saathi's own fixed sentences are English. With Tamil configured they must not be handed to
    /// the Tamil synthesiser — and a Tamil reply must not be handed to the English one.
    func testALineIsReadInTheLanguageItIsWrittenIn() {
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "I did not catch that. Say it once more?", wanted: "ta-IN"), "en")
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "நான் அதைக் கேட்கவில்லை. மீண்டும் சொல்லுங்கள்.", wanted: "ta-IN"), "ta-IN")
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "मैंने वह नहीं सुना। एक बार फिर कहिए।", wanted: "hi"), "hi")
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "Je n'ai pas compris. Pouvez-vous répéter, s'il vous plaît ?", wanted: "fr-FR"), "fr-FR")
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "Hold control and option whenever you want me.", wanted: "fr-FR"), "en")
    }

    func testEnglishConfiguredOrNothingConfiguredIsLeftAlone() {
        XCTAssertEqual(SpeechSettings.spokenLanguage(of: "Bonjour tout le monde", wanted: "en-IN"), "en-IN")
        XCTAssertNil(SpeechSettings.spokenLanguage(of: "hello", wanted: nil))
    }

    func testSlowIsSlowerWhateverTheToneAndTheTonesKeepTheirOwnNumbers() {
        XCTAssertEqual(SpeechSettings.rateMultiplier(tone: .neutral, pace: nil), 1.0)
        XCTAssertEqual(SpeechSettings.rateMultiplier(tone: .neutral, pace: .normal), 1.0)
        XCTAssertEqual(SpeechSettings.rateMultiplier(tone: .calm, pace: nil), 0.9)
        XCTAssertEqual(SpeechSettings.rateMultiplier(tone: .encouraging, pace: .slow), 0.85)
        XCTAssertEqual(SpeechSettings.rateMultiplier(tone: .calm, pace: .slow), 0.9 * 0.85, accuracy: 0.0001)
        XCTAssertEqual(SpeechSettings.pitchMultiplier(tone: .calm), 0.95)
        XCTAssertEqual(SpeechSettings.pitchMultiplier(tone: .encouraging), 1.08)
    }

    func testSettingsComeFromTheConfiguration() {
        let settings = SpeechSettings(SaathiConfiguration(language: "ta-IN", pace: .slow))
        XCTAssertEqual(settings, SpeechSettings(language: "ta-IN", pace: .slow))
    }
}
