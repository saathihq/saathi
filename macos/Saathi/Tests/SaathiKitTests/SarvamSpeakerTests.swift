//
//  SarvamSpeakerTests.swift
//  SaathiKitTests
//
//  Sarvam's mouth, and the one voice that chooses between it and this Mac's. Nothing here makes a
//  sound: the player is a fake that writes down what it was handed, and the system voice is one
//  that writes down what it was asked to say.
//

import Foundation
import os
import XCTest
@testable import SaathiContract
@testable import SaathiKit

/// Writes down the clips it was asked to play. Can be told to wait, for tests about being stopped.
final class FakeOutput: AudioOutput, @unchecked Sendable {
    let played = Collected<Data>()
    let stops = Collected<Bool>()
    private let waits: Bool
    private let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    init(waits: Bool = false) { self.waits = waits }

    func play(_ wav: Data) async throws {
        played.add(wav)
        guard waits else { return }
        await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
        }
    }

    func stop() {
        stops.add(true)
        let continuation = waiting.withLock { waiting -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// This Mac's voice, as a test sees it: what it was told, what it said, and that it was stopped.
final class FakeDeviceVoice: DeviceVoice, @unchecked Sendable {
    let log = Collected<String>()
    let settings = Collected<SpeechSettings>()

    func apply(_ settings: SpeechSettings) { self.settings.add(settings) }
    func speak(_ text: String, tone: Tone) async { log.add("say: \(text)") }
    func stop() { log.add("stop") }

    var said: [String] { log.all.filter { $0.hasPrefix("say: ") }.map { String($0.dropFirst(5)) } }
}

final class SarvamSpeakerTests: XCTestCase {

    private let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 64), sampleRate: 24_000)

    private var audio: StubHTTP.Reply { .json(["audios": [clip.base64EncodedString()]]) }

    private func speaker(
        _ replies: [StubHTTP.Reply],
        voice: SarvamSpeaker.Voice = SarvamSpeaker.Voice(language: "ml"),
        output: FakeOutput = FakeOutput(),
        fallback: @escaping SarvamSpeaker.Fallback = { _, _, _ in }
    ) -> SarvamSpeaker {
        SarvamSpeaker(
            client: SarvamClient(key: "sk-sarvam", urlSession: StubHTTP.session(replies)),
            voice: voice, output: output, fallback: fallback)
    }

    func testALineIsAskedOfBulbulAndPlayed() async throws {
        let output = FakeOutput()
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "ml", speaker: "ishita"), output: output)

        await sarvam.speak("നമസ്കാരം, ഞാൻ സഹായിക്കാം.", tone: .neutral)

        XCTAssertEqual(output.played.all, [clip])
        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(seen.json["text"] as? String, "നമസ്കാരം, ഞാൻ സഹായിക്കാം.")
        XCTAssertEqual(seen.json["language_code"] as? String, "ml-IN")
        XCTAssertEqual(seen.json["speaker"] as? String, "ishita")
        XCTAssertNil(seen.json["pace"])
    }

    /// Saathi's own fixed sentences are English. Bulbul is told so, as the system voice is, so that
    /// "I did not catch that" is read as English rather than normalised as Malayalam.
    func testALineIsSpokenInTheLanguageItIsWrittenIn() {
        XCTAssertEqual(SarvamSpeaker.code(for: "I did not catch that. Say it once more?", in: "ml"), "en-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "നമസ്കാരം, ഞാൻ സഹായിക്കാം.", in: "ml"), "ml-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "मैंने वह नहीं सुना। एक बार फिर कहिए।", in: "hi-IN"), "hi-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "Hello there, how can I help?", in: "en"), "en-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "OK", in: "ta"), "en-IN", "Latin letters are English to a Tamil speaker's Saathi")
        XCTAssertEqual(SarvamSpeaker.code(for: "42", in: "ta"), "ta-IN", "nothing to tell a language by: the language of Settings")
    }

    /// Calm is a little slower, and a learner who asked for slow gets slower again — the same two
    /// numbers the system voice uses, sent as Bulbul's `pace`.
    func testTheToneAndThePaceAskedForReachBulbul() async throws {
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "hi", pace: .slow))
        await sarvam.speak("ठीक है, धीरे-धीरे चलते हैं।", tone: .calm)
        let pace = try XCTUnwrap(StubHTTP.seen.first?.json["pace"] as? Double)
        XCTAssertEqual(pace, 0.76, accuracy: 0.011)

        let ordinary = speaker([audio], voice: SarvamSpeaker.Voice(language: "hi"))
        await ordinary.speak("ठीक है।", tone: .neutral)
        XCTAssertNil(StubHTTP.seen.first?.json["pace"])
    }

    /// Bulbul takes 2500 characters. A reply is a sentence or two; this is for the one that is not.
    func testALongReplyIsCutWhereAListenerWouldBreathe() async throws {
        let sentence = "This is one sentence of a very long reply that goes on. "
        let long = String(repeating: sentence, count: 110)   // about 6,000 characters
        let pieces = SarvamSpeaker.pieces(of: long)

        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, SarvamClient.longestUtterance)
            XCTAssertTrue(piece.hasSuffix("goes on."), "cut at the end of a sentence, not through one")
        }
        XCTAssertEqual(
            pieces.joined(separator: " "), long.trimmingCharacters(in: .whitespaces),
            "every word is still there, in order")

        let output = FakeOutput()
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "en"), output: output)
        await sarvam.speak(long, tone: .neutral)
        XCTAssertEqual(StubHTTP.seen.count, pieces.count)
        XCTAssertEqual(output.played.all.count, pieces.count)
    }

    func testPiecesOfOrdinaryAndAwkwardText() {
        XCTAssertEqual(SarvamSpeaker.pieces(of: "  One short line.  "), ["One short line."])
        XCTAssertTrue(SarvamSpeaker.pieces(of: "   ").isEmpty)
        // One sentence longer than a request: cut at spaces.
        let run = String(repeating: "word ", count: 700)
        let cut = SarvamSpeaker.pieces(of: run, limit: 1_000)
        XCTAssertGreaterThan(cut.count, 1)
        XCTAssertTrue(cut.allSatisfy { $0.count <= 1_000 && !$0.hasPrefix(" ") && !$0.contains("wo rd") })
        XCTAssertEqual(cut.joined(separator: " "), run.trimmingCharacters(in: .whitespaces))
        // And a run with nowhere to cut at all is cut where the limit falls rather than refused.
        let solid = String(repeating: "x", count: 2_500)
        let chunks = SarvamSpeaker.pieces(of: solid, limit: 1_000)
        XCTAssertEqual(chunks.map(\.count), [1_000, 1_000, 500])
    }

    /// Going silent is the worse failure for someone who cannot see why.
    func testWhenBulbulCannotBeReachedTheLineGoesToTheFallbackWithTheReason() async {
        let handed = Collected<String>()
        let output = FakeOutput()
        let sarvam = speaker([.failing()], output: output, fallback: { text, tone, reason in
            handed.add("\(text) | \(tone.rawValue) | \(reason)")
        })

        await sarvam.speak("നമസ്കാരം.", tone: .calm)

        XCTAssertTrue(output.played.all.isEmpty)
        XCTAssertEqual(handed.all.count, 1)
        XCTAssertTrue(handed.all[0].hasPrefix("നമസ്കാരം. | calm | Could not reach Sarvam"), handed.all[0])
    }

    func testARefusalGoesToTheFallbackInSarvamsOwnSentence() async {
        let reasons = Collected<String>()
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "insufficient_quota_error"]], status: 429)
        let sarvam = speaker([refused], fallback: { _, _, reason in reasons.add(reason) })
        await sarvam.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(reasons.all, [SarvamError.outOfCredits.localizedDescription])
    }

    /// Cut off on purpose is not a failure to speak: nothing goes to the fallback, and the rest of
    /// a long line is not asked for.
    func testStoppingCutsTheLineAndSaysNoMore() async throws {
        let output = FakeOutput(waits: true)
        let fellBack = Collected<String>()
        let long = String(repeating: "A sentence that is part of a long reply. ", count: 150)
        let sarvam = speaker(
            [audio], voice: SarvamSpeaker.Voice(language: "en"), output: output,
            fallback: { text, _, _ in fellBack.add(text) })

        let speaking = Task { await sarvam.speak(long, tone: .neutral) }
        for _ in 0..<400 where output.played.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(output.played.all.count, 1, "the first piece is playing")

        sarvam.stop()
        await speaking.value

        XCTAssertEqual(StubHTTP.seen.count, 1, "the second piece was never asked for")
        XCTAssertEqual(output.stops.all.count, 1)
        XCTAssertTrue(fellBack.all.isEmpty)
    }
}

/// The real player. It opens the audio output, so — like every test that touches the hardware —
/// it only runs when asked, and what it plays is silence:
///
///     SAATHI_AUDIO_TESTS=1 swift test --filter PlayerAudioOutputTests
final class PlayerAudioOutputTests: XCTestCase {

    private func skipUnlessAsked() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAATHI_AUDIO_TESTS"] == "1",
            "opens the real audio output; set SAATHI_AUDIO_TESTS=1 to run it")
    }

    private func silence(seconds: Int) -> Data {
        WaveFile.wrap(pcm16: Data(count: seconds * 48_000), sampleRate: 24_000)
    }

    func testAClipIsPlayedToItsEndAndThenTheCallReturns() async throws {
        try skipUnlessAsked()
        let started = Date()
        try await PlayerAudioOutput().play(silence(seconds: 1))
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(took, 0.8, "it waited for the clip")
        XCTAssertLessThan(took, 1.9, "and came back when the clip ended, not at the backstop")
    }

    func testStoppingCutsAClipShort() async throws {
        try skipUnlessAsked()
        let output = PlayerAudioOutput()
        let playing = Task { try await output.play(self.silence(seconds: 10)) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let stopped = Date()
        output.stop()
        try await playing.value
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 1)
    }

    /// Nothing is opened for this one: the data is refused before there is anything to play.
    func testSomethingThatIsNotAudioIsAnErrorRatherThanAWait() async {
        do {
            try await PlayerAudioOutput().play(Data("this is not a wav file".utf8))
            XCTFail("that was not audio")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be played"), error.localizedDescription)
        }
    }
}

final class SarvamSpeechTests: XCTestCase {

    func testSarvamsSpeechIsOnlyOnWhenItWasAskedForAndOnlyOnTheChainLane() {
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k")), "asked for, not assumed")
        XCTAssertTrue(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)))
        XCTAssertTrue(SarvamSpeech.isOn(SaathiConfiguration(sarvamKey: "k", speech: .sarvam)), "a local model can have Sarvam's ears")
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .openai, openaiKey: "k", speech: .sarvam)), "the realtime lane carries its own")
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .device)))
    }

    func testTheSettingsAreTheKeyTheLanguageInSarvamsSpellingAndTheVoice() throws {
        let settings = try SarvamSpeech.settings(for: SaathiConfiguration(
            provider: .sarvam, sarvamKey: " sk-sarvam ", voice: "Ishita", speech: .sarvam, language: "ml"))
        XCTAssertEqual(settings, SarvamSpeech.Settings(key: "sk-sarvam", language: "ml-IN", speaker: "ishita"))

        let plain = try SarvamSpeech.settings(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam))
        XCTAssertEqual(plain.language, "en-IN", "English until a language is chosen")
        XCTAssertEqual(plain.speaker, "shubh")
    }

    func testTheLegacySharedKeyStillServesAConfigThatNamesSarvam() throws {
        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy", speech: .sarvam)
        XCTAssertEqual(try SarvamSpeech.settings(for: legacy).key, "sk-legacy")
    }

    /// Another vendor's key is not a Sarvam key, however it is spelled in the file. It used to be
    /// taken for one, and a turn's audio went up with an Anthropic key on it.
    func testAnotherVendorsSharedKeyIsNotSentToSarvam() {
        let claude = SaathiConfiguration(provider: .anthropic, apiKey: "sk-ant", speech: .sarvam)
        XCTAssertThrowsError(try SarvamSpeech.settings(for: claude)) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs a Sarvam key"), error.localizedDescription)
        }
        XCTAssertThrowsError(try VoiceSessionFactory.make(configuration: claude, speaker: PrintingSpeaker()))
    }

    func testNoKeyIsSaidNotWorkedAround() {
        XCTAssertThrowsError(try SarvamSpeech.settings(for: SaathiConfiguration(speech: .sarvam))) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs a Sarvam key"), error.localizedDescription)
        }
    }

    /// French with Sarvam's speech does not quietly listen on this Mac instead.
    func testALanguageSarvamDoesNotSpeakIsARefusalThatNamesIt() {
        let french = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "fr")
        XCTAssertThrowsError(try SarvamSpeech.settings(for: french)) { error in
            XCTAssertTrue(error.localizedDescription.contains("French is not one of them"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Choose another language"), error.localizedDescription)
        }
    }

    /// A realtime voice left behind by another provider, or a typo, would fail every sentence.
    func testAVoiceBulbulDoesNotHaveIsNotSent() {
        XCTAssertEqual(SarvamSpeech.speaker(named: "cedar"), "shubh")
        XCTAssertEqual(SarvamSpeech.speaker(named: "  PRIYA "), "priya")
        XCTAssertEqual(SarvamSpeech.speaker(named: nil), "shubh")
        XCTAssertEqual(SarvamSpeech.speaker(named: ""), "shubh")
        XCTAssertTrue(SarvamClient.speakers.contains(SarvamClient.defaultSpeaker))
    }
}

final class CompanionVoiceTests: XCTestCase {

    private let malayalam = SaathiConfiguration(
        provider: .sarvam, sarvamKey: "sk-sarvam", speech: .sarvam, language: "ml", pace: .slow)
    private let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 64), sampleRate: 24_000)

    private func voice(
        _ configuration: SaathiConfiguration,
        device: FakeDeviceVoice = FakeDeviceVoice(),
        output: FakeOutput = FakeOutput(),
        replies: [StubHTTP.Reply]? = nil,
        installedVoices: [String] = ["en-US", "hi-IN"]
    ) -> CompanionVoice {
        let audio = StubHTTP.Reply.json(["audios": [clip.base64EncodedString()]])
        return CompanionVoice(
            configuration: configuration, device: device, output: { output },
            urlSession: StubHTTP.session(replies ?? [audio]), installedVoices: installedVoices)
    }

    func testTheVoiceIsThisMacsUntilSarvamsIsAskedFor() async {
        let device = FakeDeviceVoice()
        let onDevice = voice(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", language: "hi"), device: device)
        XCTAssertFalse(onDevice.speaksThroughSarvam)

        await onDevice.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(device.said, ["नमस्ते।"])
        XCTAssertTrue(StubHTTP.seen.isEmpty, "nothing is sent to Sarvam that was not asked to be")
        XCTAssertEqual(device.settings.all.last, SpeechSettings(language: "hi", pace: nil), "and it is told the language to read in")
    }

    func testWithSarvamsSpeechEveryLineIsSarvams() async throws {
        let device = FakeDeviceVoice()
        let output = FakeOutput()
        let sarvam = voice(malayalam, device: device, output: output)
        XCTAssertTrue(sarvam.speaksThroughSarvam)

        await sarvam.speak("നമസ്കാരം.", tone: .neutral)

        XCTAssertEqual(output.played.all, [clip])
        XCTAssertTrue(device.said.isEmpty)
        let asked = try XCTUnwrap(StubHTTP.seen.first?.json)
        XCTAssertEqual(asked["language_code"] as? String, "ml-IN")
        XCTAssertNotNil(asked["pace"], "slow was asked for in first run, and Bulbul is told")
    }

    /// First run's lines are English, and are read by this Mac's English voice whatever has been
    /// configured — before anything has been said about where a voice might go.
    func testFirstRunIsAlwaysThisMacsEnglishVoice() async {
        let device = FakeDeviceVoice()
        let scripted = voice(malayalam, device: device)
        scripted.apply(malayalam, scripted: true)
        XCTAssertFalse(scripted.speaksThroughSarvam)
        XCTAssertEqual(device.settings.all.last, SpeechSettings(language: "en-US", pace: .slow), "the pace still follows at once")

        scripted.apply(malayalam)
        XCTAssertTrue(scripted.speaksThroughSarvam, "and afterwards it is whatever was chosen")
        XCTAssertEqual(CompanionVoice.deviceSettings(for: malayalam, scripted: false), SpeechSettings(language: "ml", pace: .slow))
    }

    func testAConfigurationSarvamCannotSpeakForFallsToThisMacsVoiceSoTheReasonCanBeSaid() {
        let french = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "fr")
        XCTAssertFalse(voice(french).speaksThroughSarvam)
        XCTAssertFalse(voice(SaathiConfiguration(speech: .sarvam)).speaksThroughSarvam, "no key")
        XCTAssertFalse(voice(SaathiConfiguration(provider: .openai, openaiKey: "k", speech: .sarvam)).speaksThroughSarvam)
    }

    /// When Bulbul cannot be reached Saathi still makes a sound, and says why where it can be seen.
    func testWhenSarvamCannotSpeakThisMacDoesIfItCanReadTheLanguageAndSaysSoIfItCannot() async {
        let hindi = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "hi")
        let reasons = Collected<String>()

        let device = FakeDeviceVoice()
        let canRead = voice(hindi, device: device, replies: [.failing()], installedVoices: ["en-US", "hi-IN"])
        canRead.reportFailures { reasons.add($0) }
        await canRead.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(device.said, ["नमस्ते।"], "this Mac has a Hindi voice: the line itself")

        let other = FakeDeviceVoice()
        let cannotRead = voice(malayalam, device: other, replies: [.failing()], installedVoices: ["en-US", "hi-IN"])
        cannotRead.reportFailures { reasons.add($0) }
        await cannotRead.speak("നമസ്കാരം.", tone: .neutral)
        XCTAssertEqual(other.said, ["I could not speak through Sarvam just now."], "an English voice reading Malayalam script is noise")

        XCTAssertEqual(reasons.all.count, 2)
        XCTAssertTrue(reasons.all.allSatisfy { $0.hasPrefix("Sarvam could not speak: Could not reach Sarvam") }, "\(reasons.all)")
    }

    /// Holding the keys to talk over Saathi must not be answered by the next thing it had queued.
    func testALineAskedForBeforeAStopIsNotSaidAfterIt() async throws {
        let device = FakeDeviceVoice()
        let output = FakeOutput(waits: true)
        let sarvam = voice(malayalam, device: device, output: output)

        let first = Task { await sarvam.speak("ഒന്ന്.", tone: .neutral) }
        for _ in 0..<400 where output.played.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let second = Task { await sarvam.speak("രണ്ട്.", tone: .neutral) }
        try await Task.sleep(nanoseconds: 30_000_000)

        sarvam.stop()
        await first.value
        await second.value
        XCTAssertEqual(output.played.all.count, 1, "the queued line was dropped, not played late")
        XCTAssertEqual(device.log.all, ["stop"])

        let third = Task { await sarvam.speak("മൂന്ന്.", tone: .neutral) }
        for _ in 0..<400 where output.played.all.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(output.played.all.count, 2, "and a line asked for after the stop is said")
        sarvam.stop()
        await third.value
    }

    func testThisMacCanOnlyReadALanguageItHasAVoiceFor() {
        let installed = ["en-US", "en-IN", "hi-IN", "ta-IN"]
        XCTAssertTrue(SpeechSettings.hasVoice(for: "hi", available: installed))
        XCTAssertTrue(SpeechSettings.hasVoice(for: "TA-in", available: installed))
        XCTAssertFalse(SpeechSettings.hasVoice(for: "ml", available: installed))
        XCTAssertFalse(SpeechSettings.hasVoice(for: "e", available: installed), "a prefix of a code is not the code")
    }
}
