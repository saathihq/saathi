//
//  SarvamEarsTests.swift
//  SaathiKitTests
//
//  Sarvam's ears, with a microphone a test controls: what is sent to Saaras for a held turn, what
//  is never sent at all, and what a long turn becomes. The real microphone is one small class
//  behind `TurnRecorder`; nothing here opens it.
//

import AVFoundation
import Foundation
import os
import XCTest
@testable import SaathiKit

/// A microphone that "records" whatever a test hands it.
final class FakeRecorder: TurnRecorder, @unchecked Sendable {
    let calls = Collected<String>()
    private let turn: RecordedTurn
    private let refusal: (any Error)?

    init(recording turn: RecordedTurn = RecordedTurn(), refusing refusal: (any Error)? = nil) {
        self.turn = turn
        self.refusal = refusal
    }

    /// `seconds` of something at `peak`, as PCM16 at Saaras's rate.
    static func turn(seconds: Double, peak: Float = 0.3) -> RecordedTurn {
        let samples = Int(seconds * SarvamEars.sampleRate)
        return RecordedTurn(pcm16: Data(repeating: 3, count: samples * 2), peak: peak)
    }

    func prepare() async throws {
        calls.add("prepare")
        if let refusal { throw refusal }
    }

    func start(onLevel: (@Sendable (Float) -> Void)?) throws {
        calls.add("start")
        onLevel?(0.4)
    }

    func stop() -> RecordedTurn {
        calls.add("stop")
        return turn
    }
}

/// A clock a test moves by hand, for how long the keys were held.
final class HandClock: @unchecked Sendable {
    private let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))

    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

final class SarvamEarsTests: XCTestCase {

    private func makeEars(_ recorder: FakeRecorder, clock: HandClock? = nil, _ replies: StubHTTP.Reply...) -> SarvamEars {
        let client = SarvamClient(key: "sk-sarvam", urlSession: StubHTTP.session(replies))
        guard let clock else { return SarvamEars(client: client, language: "ml-IN", recorder: recorder) }
        return SarvamEars(client: client, language: "ml-IN", recorder: recorder, now: { clock.now })
    }

    func testAHeldTurnGoesToSaarasAsAWavInTheLanguageOfSettings() async throws {
        let recorder = FakeRecorder(recording: FakeRecorder.turn(seconds: 2))
        let ears = makeEars(recorder, .json(["transcript": "എന്താണ് ഇത്", "language_code": "ml-IN"]))
        let levels = Collected<Float>()

        let ready = try await ears.prepare()
        try await ears.begin(EarsFeedback(onLevel: { levels.add($0) }))
        let heard = try await ears.finish()

        XCTAssertEqual(ready, "ready — Sarvam hears you (ml-IN)")
        XCTAssertEqual(heard, "എന്താണ് ഇത്")
        XCTAssertEqual(recorder.calls.all, ["prepare", "start", "stop"])
        XCTAssertEqual(levels.all, [0.4], "the bars still move: the level comes from the microphone, not from Sarvam")

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(StubHTTP.seen.count, 1)
        XCTAssertEqual(seen.request.url?.path, "/speech-to-text")
        XCTAssertNotNil(seen.body.range(of: Data("name=\"language_code\"\r\n\r\nml-IN\r\n".utf8)))
        let wav = WaveFile.wrap(pcm16: FakeRecorder.turn(seconds: 2).pcm16, sampleRate: 16_000)
        XCTAssertNotNil(seen.body.range(of: wav), "the turn, as a 16 kHz WAV")
    }

    /// The keys tapped, not held. Nothing worth sending, and nothing is sent.
    func testATapOfTheKeysIsNotSentAnywhere() async throws {
        let ears = makeEars(FakeRecorder(recording: FakeRecorder.turn(seconds: 0.1)), .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        let heard = try await ears.finish()
        XCTAssertEqual(heard, "")
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// A microphone that gave nothing at all is a different problem from speech that was not
    /// understood, and saying which is the difference between trying again and looking at Sound
    /// settings. Saaras is not asked to transcribe it.
    func testAMicrophoneThatGaveNothingSaysSoInsteadOfAskingSaaras() async throws {
        let dead = FakeRecorder(recording: FakeRecorder.turn(seconds: 2, peak: 0))
        let ears = makeEars(dead, .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        do {
            _ = try await ears.finish()
            XCTFail("two seconds of nothing at all is not a turn")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("microphone gave no sound"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("quit and reopen"), error.localizedDescription)
        }
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// A closed input may hand over zeros, or may hand over nothing at all. Keys held for two
    /// seconds with nothing recorded were not tapped: the microphone is not delivering, and "I did
    /// not catch that" would send the person to say it again into the same closed input.
    func testKeysHeldWithNothingRecordedIsTheMicrophoneNotATap() async throws {
        let clock = HandClock()
        let ears = makeEars(FakeRecorder(recording: RecordedTurn()), clock: clock, .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        clock.advance(2)
        do {
            _ = try await ears.finish()
            XCTFail("two seconds held and nothing recorded is not a tap of the keys")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("microphone gave no sound"), error.localizedDescription)
        }
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// And a tap is still a tap, however little it recorded.
    func testATapThatRecordedNothingIsStillOnlyATap() async throws {
        let clock = HandClock()
        let ears = makeEars(FakeRecorder(recording: RecordedTurn()), clock: clock, .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        clock.advance(0.2)
        let heard = try await ears.finish()
        XCTAssertEqual(heard, "")

        // A microphone that is slow to start is not a closed one: a second of holding for a
        // quarter of a second of sound is still given the benefit of the doubt.
        let slow = makeEars(FakeRecorder(recording: FakeRecorder.turn(seconds: 0.25)), clock: clock, .json(["transcript": "never asked"]))
        try await slow.begin(EarsFeedback())
        clock.advance(1.2)
        let again = try await slow.finish()
        XCTAssertEqual(again, "")
    }

    /// Someone who held the keys and then said nothing has a working microphone in a quiet room.
    /// They are told Saathi did not catch that, like on every other lane — not sent to their Sound
    /// settings — and the sound of their room is not sent to Sarvam.
    func testAQuietRoomIsNothingSaidNotABrokenMicrophone() async throws {
        let quiet = FakeRecorder(recording: FakeRecorder.turn(seconds: 2, peak: 0.004))
        let ears = makeEars(quiet, .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        let heard = try await ears.finish()
        XCTAssertEqual(heard, "")
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// Saaras takes thirty seconds a request. A longer turn goes up in pieces rather than being
    /// refused whole.
    func testALongTurnGoesUpInPiecesAndComesBackAsOneSentence() async throws {
        let long = FakeRecorder.turn(seconds: 65)
        let ears = makeEars(
            FakeRecorder(recording: long),
            .json(["transcript": "one"]), .json(["transcript": ""]), .json(["transcript": "three"]))
        try await ears.begin(EarsFeedback())
        let heard = try await ears.finish()

        XCTAssertEqual(heard, "one three", "a piece with nothing in it adds nothing")
        XCTAssertEqual(StubHTTP.seen.count, 3)

        let pieces = SarvamEars.pieces(of: long.pcm16)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), long.pcm16.count, "nothing is lost at the cuts")
        for piece in pieces {
            XCTAssertLessThanOrEqual(Double(piece.count / 2) / 16_000, 28)
            XCTAssertEqual(piece.count % 2, 0, "cut on a sample, never through one")
        }
        XCTAssertEqual(SarvamEars.pieces(of: FakeRecorder.turn(seconds: 5).pcm16).count, 1)
        XCTAssertTrue(SarvamEars.pieces(of: Data()).isEmpty)
    }

    func testSaarasRefusingIsTheRefusalItGave() async throws {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        let ears = makeEars(FakeRecorder(recording: FakeRecorder.turn(seconds: 2)), refused)
        try await ears.begin(EarsFeedback())
        do {
            _ = try await ears.finish()
            XCTFail("a refused key is not a turn in which nothing was said")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
    }

    func testARefusedMicrophoneStopsTheSessionBeforeItStarts() async {
        let denied = VoiceError.notConfigured("Saathi needs the microphone to hear you.")
        let ears = makeEars(FakeRecorder(refusing: denied), .json([:]))
        do {
            _ = try await ears.prepare()
            XCTFail("no microphone, no ears")
        } catch {
            XCTAssertEqual(error as? VoiceError, denied)
        }
    }

    func testCancellingLetsGoOfTheMicrophone() {
        let recorder = FakeRecorder()
        makeEars(recorder, .json([:])).cancel()
        XCTAssertEqual(recorder.calls.all, ["stop"])
    }

    func testARecordedTurnKnowsHowLongItIs() {
        XCTAssertEqual(FakeRecorder.turn(seconds: 2).seconds, 2, accuracy: 0.001)
        XCTAssertEqual(RecordedTurn().seconds, 0)
    }

    // MARK: the one step between the microphone and Saaras that can be tested without either

    /// Tap buffers as they arrive from a microphone — 48 kHz, float, more than one channel — come
    /// out as PCM16 mono at 16 kHz, and as one unbroken stretch of sound: the converter is kept
    /// from one buffer to the next, so what it holds back at the end of each is the start of the
    /// next rather than a gap. No audio hardware: the buffers are made by hand.
    func testTapBuffersBecomeOneUnbrokenStretchOfPCM16MonoAtSixteenKilohertz() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono, to: MicrophoneTurnRecorder.format))

        var samples = 0
        var loudest: Int16 = 0
        let chunks = 30   // three seconds, a tenth of a second at a time
        for chunk in 0..<chunks {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let left = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<4_800 {
                left[index] = Float(sin(Double(chunk * 4_800 + index) * 2 * .pi * 440 / 48_000)) * 0.5
            }
            let pcm = MicrophoneTurnRecorder.convert(buffer, mono: mono, with: converter)
            XCTAssertEqual(pcm.count % 2, 0)
            samples += pcm.count / 2
            pcm.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) { loudest = max(loudest, abs(sample)) }
            }
        }
        // Three seconds in is three seconds out at a third of the rate, less the few milliseconds
        // the converter is still holding when the turn ends: 262 samples after ten buffers, when
        // it was measured. Were it dropping that at every buffer instead of carrying it into the
        // next, thirty buffers would be short by thousands.
        let expected = chunks * 1_600
        XCTAssertLessThanOrEqual(samples, expected)
        XCTAssertGreaterThan(samples, expected - 480, "no more than thirty milliseconds held back, however long the turn")
        XCTAssertGreaterThan(loudest, 12_000, "half scale in is about half scale out: the first channel, not silence")
        XCTAssertLessThan(loudest, 20_000)
    }

    func testAnEmptyBufferConvertsToNothing() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono, to: MicrophoneTurnRecorder.format))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16))
        XCTAssertTrue(MicrophoneTurnRecorder.convert(empty, mono: mono, with: converter).isEmpty)
    }
}
