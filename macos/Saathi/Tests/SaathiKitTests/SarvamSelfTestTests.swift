//
//  SarvamSelfTestTests.swift
//  SaathiKitTests
//
//  `saathi sarvam`, against a script: the four requests it makes, in order, and that each line says
//  what came back or exactly what refused. The command itself is for a real key; this is so that
//  the day someone runs it, a failure is Sarvam's and not the command's.
//

import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class SarvamSelfTestTests: XCTestCase {

    private let clip = WaveFile.wrap(pcm16: Data(count: 48_000), sampleRate: 24_000)   // one second

    private var keyAccepted: StubHTTP.Reply {
        .json(["error": ["message": "model is required", "code": "invalid_request_error"]], status: 400)
    }
    private var audio: StubHTTP.Reply { .json(["audios": [clip.base64EncodedString()]]) }
    private func heard(_ text: String) -> StubHTTP.Reply { .json(["transcript": text]) }
    private func said(_ text: String) -> StubHTTP.Reply {
        .json(["choices": [["message": ["role": "assistant", "content": text]]]])
    }

    private func run(_ configuration: SaathiConfiguration, _ replies: StubHTTP.Reply...) async -> [SarvamSelfTest.Line] {
        await SarvamSelfTest(configuration: configuration, urlSession: StubHTTP.session(replies)).run()
    }

    func testWithEverythingWorkingItSaysSoInFourLines() async throws {
        let malayalam = SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam", voice: "ishita", language: "ml")
        let lines = await run(malayalam, keyAccepted, audio, heard("നമസ്കാരം, ഞാൻ Saathi."), said("നമസ്കാരം!"))

        XCTAssertEqual(lines.map(\.step), ["key", "speech out", "speech in", "thinking"])
        XCTAssertTrue(lines.allSatisfy(\.passed), "\(lines)")
        XCTAssertEqual(lines[0].detail, "accepted")
        XCTAssertEqual(lines[1].detail, "1.0 s of audio for \"നമസ്കാരം, ഞാൻ Saathi.\" (ml-IN, ishita)")
        XCTAssertEqual(lines[2].detail, "heard \"നമസ്കാരം, ഞാൻ Saathi.\"")
        XCTAssertEqual(lines[3].detail, "sarvam-105b said \"നമസ്കാരം!\"")

        let paths = StubHTTP.seen.map { $0.request.url?.path ?? "" }
        XCTAssertEqual(paths, ["/v1/chat/completions", "/text-to-speech", "/speech-to-text", "/v1/chat/completions"])
        XCTAssertNotNil(StubHTTP.seen[2].body.range(of: clip), "Saaras is handed the audio Bulbul made: no microphone")
    }

    /// The thinking step sends exactly what a turn sends — the tools, and the request not to think
    /// aloud — because a refusal of either is what would otherwise look like a companion that
    /// never answers.
    func testTheThinkingStepIsExactlyWhatATurnSends() async throws {
        _ = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("x"), said("hello"))
        let asked = try XCTUnwrap(StubHTTP.seen.last?.json)
        XCTAssertEqual((asked["tools"] as? [[String: Any]])?.count, SaathiAction.allWireNames.count)
        XCTAssertTrue(asked["reasoning_effort"] is NSNull)
        XCTAssertEqual(asked["model"] as? String, "sarvam-105b")
        XCTAssertEqual(StubHTTP.seen.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    /// Sarvam is what is being tested, whatever this configuration thinks with.
    func testItAsksSarvamItselfEvenWhenSaathiThinksSomewhereElse() async throws {
        let elsewhere = SaathiConfiguration(
            provider: .openai, providerBaseUrl: "http://192.168.1.9:11434", model: "gpt-4o",
            openaiKey: "sk-openai", sarvamKey: "sk-sarvam")
        let lines = await run(elsewhere, keyAccepted, audio, heard("Hello, I am Saathi."), said("Hello!"))
        XCTAssertTrue(lines.allSatisfy(\.passed), "\(lines)")
        let thinking = try XCTUnwrap(StubHTTP.seen.last)
        XCTAssertEqual(thinking.request.url?.absoluteString, "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(thinking.request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-sarvam")
        XCTAssertEqual(thinking.json["model"] as? String, "sarvam-105b")
        XCTAssertEqual(StubHTTP.seen[1].json["language_code"] as? String, "en-IN", "English until a language is chosen")
    }

    func testWithNoKeyItSaysWhereToPutOneAndAsksNothing() async {
        let lines = await run(SaathiConfiguration(provider: .openai, openaiKey: "sk-openai"), keyAccepted)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].passed)
        XCTAssertTrue(lines[0].detail.contains("sarvamKey"), lines[0].detail)
        XCTAssertTrue(StubHTTP.seen.isEmpty, "another vendor's key is not tried on Sarvam")
    }

    /// Nothing after a refused key can work, and three more lines saying so would bury the one
    /// that matters.
    func testARefusedKeyIsTheOnlyLine() async {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "nope"), refused)
        XCTAssertEqual(lines, [SarvamSelfTest.Line(step: "key", passed: false, detail: "Sarvam did not accept that key.")])
        XCTAssertEqual(StubHTTP.seen.count, 1)
    }

    func testEachStepThatFailsSaysWhyAndTheOthersAreStillTried() async {
        let spent = StubHTTP.Reply.json(["error": ["message": "no", "code": "insufficient_quota_error"]], status: 429)
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, spent, said("Hello!"))
        XCTAssertEqual(lines.map(\.passed), [true, false, false, true])
        XCTAssertEqual(lines[1].detail, SarvamError.outOfCredits.localizedDescription)
        XCTAssertEqual(lines[2].detail, "not tried: there was no audio to hear")
        XCTAssertEqual(StubHTTP.seen.count, 3, "the thinking step does not depend on the speech")
    }

    func testHearingNothingBackIsAFailureAndSoIsAnAnswerWithNothingInIt() async {
        let lines = await run(
            SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("  "), said("  "))
        XCTAssertEqual(lines.map(\.passed), [true, true, false, false])
        XCTAssertEqual(lines[2].detail, "Saaras heard nothing in the audio Bulbul had just made")
        XCTAssertEqual(lines[3].detail, "sarvam-105b answered with nothing at all")
    }

    /// A model that answers "say hello" by calling the `say` tool has answered.
    func testAnAnswerThatIsAToolCallCounts() async {
        let called = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "c", "type": "function", "function": ["name": "say", "arguments": "{\"text\":\"Hello!\"}"]]],
        ]]]])
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("x"), called)
        XCTAssertTrue(lines[3].passed)
        XCTAssertEqual(lines[3].detail, "sarvam-105b answered with a tool call (say)")
    }

    func testTheClipIsHandedOverForAnyoneWhoWantsToHearIt() async {
        let clips = Collected<Data>()
        _ = await SarvamSelfTest(
            configuration: SaathiConfiguration(provider: .sarvam, sarvamKey: "k"),
            urlSession: StubHTTP.session(keyAccepted, audio, heard("x"), said("hello"))
        ).run(onClip: { clips.add($0) })
        XCTAssertEqual(clips.all, [clip])
    }

    func testTheLinesAreSetOutInAColumnAndAFailureSaysItIsOne() {
        let text = SarvamSelfTest.render([
            SarvamSelfTest.Line(step: "key", passed: true, detail: "accepted"),
            SarvamSelfTest.Line(step: "speech out", passed: false, detail: "Sarvam is busy."),
        ])
        XCTAssertEqual(text, "  key         accepted\n  speech out  FAILED — Sarvam is busy.")
    }

    func testThereIsAGreetingForEveryLanguageBulbulSpeaksAndTheNameStaysInLatin() {
        for language in SarvamLanguage.spoken {
            let greeting = SarvamSelfTest.greetings["\(language)-IN"]
            XCTAssertNotNil(greeting, language)
            XCTAssertTrue(greeting?.contains("Saathi") ?? false, language)
        }
        XCTAssertEqual(SarvamSelfTest.greetings.count, SarvamLanguage.spoken.count)
    }
}
