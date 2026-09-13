//
//  VoiceTests.swift
//  SaathiKitTests
//
//  The voice layer, tested at the three places it can silently go wrong:
//
//  1. The lane a provider gets, which is a promise about where the learner's voice goes.
//  2. Parsing a model's tool call, which is where a mishearing either stays contained or does not.
//  3. The audio engine's render-thread race, which is the bug this port exists to not re-find.
//

import AVFoundation
import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

// MARK: - Which lane, and what it promises

final class VoiceLaneTests: XCTestCase {

    /// The lane is a capability of the provider, not a setting. If this table ever changes, it is
    /// because a provider gained or lost an API — which is exactly when someone should be made to
    /// look at it.
    func testEveryProviderDeclaresALaneAndOnlyRealProviderSocketsAreRealtime() {
        let lanes = Dictionary(uniqueKeysWithValues: SaathiProvider.all.map { ($0.kind, $0.voice) })
        XCTAssertEqual(lanes[.local], .chain, "Ollama has no duplex realtime API")
        XCTAssertEqual(lanes[.anthropic], .chain, "Anthropic has no audio API at all")
        XCTAssertEqual(lanes[.sarvam], .chain, "Sarvam has STT and TTS but no socket joining them")
        XCTAssertEqual(lanes[.openai], .realtime)
        XCTAssertEqual(lanes[.hosted], .realtime)
        XCTAssertEqual(lanes.count, ProviderKind.allCases.count, "a provider without a lane cannot be spoken to")
    }

    /// The default mode must be speakable. A companion approached from the accessibility side whose
    /// out-of-the-box configuration cannot be talked to would have the premise backwards.
    func testTheDefaultProviderCanBeSpokenTo() {
        let unconfigured = SaathiConfiguration()
        XCTAssertEqual(unconfigured.resolvedProvider, .local)
        XCTAssertEqual(unconfigured.providerRow.voice, .chain)
        XCTAssertFalse(unconfigured.providerRow.requiresKey, "the default lane must need no key")
    }

    /// The distinction the chain lane exists to make: with a cloud provider doing the thinking, the
    /// transcript leaves but the audio does not. If this line ever stops being true in the report,
    /// the report is lying about the most sensitive thing the product touches.
    func testChainLaneKeepsAudioOnTheMachineEvenForCloudProviders() {
        let sarvam = SaathiConfiguration(provider: .sarvam, apiKey: "x")
        let report = VoiceLaneReport.describe(sarvam)
        XCTAssertTrue(report.contains("lane       chain"))
        XCTAssertTrue(report.contains("speech in  on this machine"))
        XCTAssertTrue(report.contains("speech out on this machine"))
        XCTAssertTrue(report.contains("your voice stays on this machine — only the transcript is sent"))
    }

    func testRealtimeLaneSaysPlainlyThatAudioLeaves() {
        let openai = SaathiConfiguration(provider: .openai, apiKey: "x")
        let report = VoiceLaneReport.describe(openai)
        XCTAssertTrue(report.contains("lane       realtime"))
        XCTAssertTrue(report.contains("your voice leaves this machine as audio"))
    }

    func testLocalReportSaysNothingLeaves() {
        let report = VoiceLaneReport.describe(SaathiConfiguration())
        XCTAssertTrue(report.contains("provider: local  (default — nothing configured)"))
        XCTAssertTrue(report.contains("your voice stays on this machine"))
        XCTAssertFalse(report.contains("only the transcript is sent"), "nothing is sent in local mode")
    }

    /// Same input, same bytes — this is what `scripts/check-parity.sh` diffs against the C# client.
    func testTheReportIsDeterministic() {
        let configuration = SaathiConfiguration(provider: .anthropic, apiKey: "x")
        XCTAssertEqual(VoiceLaneReport.describe(configuration), VoiceLaneReport.describe(configuration))
    }
}

// MARK: - Refusing to start rather than quietly downgrading

final class VoiceSessionFactoryTests: XCTestCase {

    func testTheDefaultConfigurationGetsTheChainLaneWithNoCredentials() throws {
        let session = try VoiceSessionFactory.make(
            configuration: SaathiConfiguration(), speaker: PrintingSpeaker())
        XCTAssertEqual(session.lane, .chain)
    }

    func testRealtimeProviderGetsTheRealtimeLane() throws {
        let session = try VoiceSessionFactory.make(
            configuration: SaathiConfiguration(provider: .openai, apiKey: "sk-test"),
            speaker: PrintingSpeaker())
        XCTAssertEqual(session.lane, .realtime)
    }

    /// "No silent fallback" is the README's promise and this is where it is kept. A missing key must
    /// stop the session, never quietly route the learner's voice through a different provider.
    func testAMissingKeyRefusesInsteadOfFallingBack() {
        for kind in [ProviderKind.openai, .anthropic, .sarvam] {
            XCTAssertThrowsError(
                try VoiceSessionFactory.make(
                    configuration: SaathiConfiguration(provider: kind), speaker: PrintingSpeaker()),
                "\(kind) with no key should refuse"
            ) { error in
                guard case VoiceError.notConfigured = error else {
                    return XCTFail("\(kind) failed, but not as a configuration problem: \(error)")
                }
            }
        }
    }

    func testHostedWithoutATokenRefuses() {
        XCTAssertThrowsError(
            try VoiceSessionFactory.make(
                configuration: SaathiConfiguration(provider: .hosted), speaker: PrintingSpeaker()))
    }
}

// MARK: - Tool calls: the closed-set guarantee

final class VoiceToolCallTests: XCTestCase {

    /// The tool list handed to a model is the generated contract bytes. If this cannot be parsed,
    /// every lane silently runs with no tools at all — a failure that looks like a stupid model.
    func testTheGeneratedToolSchemaIsValidAndCoversEveryAction() throws {
        let tools = try VoiceToolCall.toolDefinitions()
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(SaathiAction.allWireNames))
    }

    /// Why the contract's enums are closed, expressed as a test: `tone` may only ever be one of
    /// three values, so a mishearing cannot invent a fourth.
    func testEnumParametersReachTheModelAsClosedSets() throws {
        let tools = try VoiceToolCall.toolDefinitions()
        let say = try XCTUnwrap(tools.first { $0["name"] as? String == "say" })
        let parameters = try XCTUnwrap(say["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let tone = try XCTUnwrap(properties["tone"] as? [String: Any])
        XCTAssertEqual(tone["enum"] as? [String], Tone.allCases.map(\.rawValue))
    }

    func testAKnownActionParsesWithItsArguments() {
        let result = VoiceToolCall.parse(name: "show_step", arguments: [
            "title": "Open the lid", "index": 2, "total": 5, "pace": "slow",
        ])
        guard case let .success(.showStep(step)) = result else { return XCTFail("did not parse: \(result)") }
        XCTAssertEqual(step.title, "Open the lid")
        XCTAssertEqual(step.index, 2)
        XCTAssertEqual(step.pace, .slow)
    }

    /// A model that invents a tool gets told so. Dropping it silently would leave the model
    /// believing it had acted, and it would then narrate something that never happened.
    func testAnInventedActionIsRefusedByName() {
        let result = VoiceToolCall.parse(name: "delete_everything", arguments: [:])
        guard case let .failure(failure) = result else { return XCTFail("should have been refused") }
        XCTAssertEqual(failure, .unknownAction("delete_everything"))
    }

    /// The mishearing case. "calm" misheard as "clam" must not lose the sentence — the words are
    /// still right, and saying them in the default tone beats saying nothing.
    func testAnOutOfSetEnumFallsBackToTheSchemaDefaultRatherThanDroppingTheLine() {
        let result = VoiceToolCall.parse(name: "say", arguments: ["text": "Nearly there", "tone": "clam"])
        guard case let .success(.say(action)) = result else { return XCTFail("the line should survive") }
        XCTAssertEqual(action.text, "Nearly there")
        XCTAssertEqual(action.tone, .neutral)
    }

    func testAMissingRequiredParameterIsRefused() {
        let result = VoiceToolCall.parse(name: "say", arguments: ["tone": "calm"])
        guard case let .failure(failure) = result else { return XCTFail("should have been refused") }
        XCTAssertEqual(failure, .missingParameter(action: "say", parameter: "text"))
    }

    /// Numbers arrive as strings or doubles depending on the model and the JSON path they took.
    func testIntegersSurviveWhicheverWayTheModelSendsThem() {
        for raw in [2 as Any, 2.0 as Any, "2" as Any] {
            let result = VoiceToolCall.parse(
                name: "show_step", arguments: ["title": "x", "index": raw, "total": 3])
            guard case let .success(.showStep(step)) = result else {
                return XCTFail("index as \(type(of: raw)) did not parse")
            }
            XCTAssertEqual(step.index, 2)
        }
    }
}

// MARK: - The realtime URL, which used to be a force-unwrap

final class RealtimeSocketURLTests: XCTestCase {

    func testHttpsBecomesWss() {
        let url = RealtimeVoiceSession.socketURL(baseURL: "https://api.openai.com/v1", model: "gpt-realtime")
        XCTAssertEqual(url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
    }

    func testATrailingSlashDoesNotDoubleUp() {
        let url = RealtimeVoiceSession.socketURL(baseURL: "https://api.openai.com/v1/", model: "m")
        XCTAssertEqual(url?.absoluteString, "wss://api.openai.com/v1/realtime?model=m")
    }

    /// A model name can arrive from a backend response. In the predecessor this path force-unwrapped
    /// and a stray space would have crashed the app rather than failing the connection.
    func testAModelNameWithSpacesOrJunkDoesNotCrash() {
        for model in ["gpt realtime", "a\"b", "ünïcode", ""] {
            let url = RealtimeVoiceSession.socketURL(baseURL: "https://api.openai.com/v1", model: model)
            XCTAssertNotNil(url, "\(model) should produce a URL or nil, never a crash")
        }
    }
}

// MARK: - The render-thread race

final class VoiceAudioEngineConcurrencyTests: XCTestCase {

    /// The reason `VoiceAudioEngine` was ported rather than rewritten.
    ///
    /// The microphone tap runs on CoreAudio's render thread; teardown runs on the engine's own
    /// queue. Reading the converter off `self` in the tap — which is what the predecessor did —
    /// races teardown nilling it. This drives both sides concurrently.
    ///
    /// **It only proves anything under the Thread Sanitizer.** The plain suite runs it as a smoke
    /// test. The command that actually checks the fix:
    ///
    ///     swift test --sanitize=thread --filter VoiceAudioEngineConcurrencyTests
    ///
    /// On the pre-fix shape that aborts with a ReportRace in `handleMicrophoneBuffer`.
    func testTearDownDuringACaptureBurstDoesNotRace() async {
        let engine = VoiceAudioEngine()
        engine.setCallbacks(onMicrophoneFrame: { _, _ in }, onPlaybackActiveChanged: { _ in })

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<2400 { channel[index] = Float(sin(Double(index) * 0.01)) * 0.2 }
        }

        // No `start()`: this test must run on a CI machine with no microphone. Driving the tap
        // handler directly is the point — it is the render thread's entry point either way.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<200 {
                    engine.handleMicrophoneBuffer(buffer)
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    engine.stop()
                    try? await Task.sleep(nanoseconds: 100_000)
                }
            }
        }

        await engine.releaseNow()
        let summary = await engine.debugSummary()
        XCTAssertTrue(summary.contains("taps"), "the engine should still answer after the burst")
    }

    /// With no capture configured the tap must return immediately rather than dereferencing
    /// anything. This is the path teardown leaves behind.
    func testTapWithNoConfiguredCaptureIsANoOp() async {
        let engine = VoiceAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        engine.handleMicrophoneBuffer(buffer)
        let summary = await engine.debugSummary()
        XCTAssertTrue(summary.contains("frames out 0"), "nothing should have been converted: \(summary)")
    }
}
