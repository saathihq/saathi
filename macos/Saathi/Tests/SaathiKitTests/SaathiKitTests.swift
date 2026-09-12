//
//  SaathiKitTests.swift
//  SaathiKitTests
//

import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class ActionPerformerTests: XCTestCase {

    // MARK: url safety

    func testHttpAndHttpsUrlsAreAccepted() throws {
        XCTAssertEqual(try ActionPerformer.validated("https://saathi.dev").host, "saathi.dev")
        XCTAssertEqual(try ActionPerformer.validated("http://example.org/a/b").host, "example.org")
        XCTAssertEqual(try ActionPerformer.validated("  https://saathi.dev  ").host, "saathi.dev")
    }

    /// The URL in an `open_url` action came from a model, which got it from speech. Every one of
    /// these would otherwise hand that chain the ability to make the OS do something unasked.
    func testEveryOtherSchemeIsRefused() {
        let hostile = [
            "file:///etc/passwd",
            "ssh://root@example.com",
            "ftp://example.com",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "vscode://file/etc/passwd",
            "smb://example.com/share",
        ]
        for raw in hostile {
            XCTAssertThrowsError(try ActionPerformer.validated(raw), "\(raw) should be refused") { error in
                guard case ActionError.unsupportedUrlScheme = error else {
                    return XCTFail("\(raw) was refused, but not as an unsupported scheme: \(error)")
                }
            }
        }
    }

    func testSchemelessAndJunkUrlsAreRefused() {
        for raw in ["saathi.dev", "", "   ", "https://"] {
            XCTAssertThrowsError(try ActionPerformer.validated(raw), "\(raw) should be refused")
        }
    }

    // MARK: step narration

    func testAStepAlwaysAnnouncesItsPlaceInTheWhole() throws {
        let step = ShowStepAction(title: "Open the lid", index: 2, total: 5)
        XCTAssertEqual(try ActionPerformer.narration(for: step), "Step 2 of 5. Open the lid.")
    }

    func testDetailIsAppendedAndPunctuated() throws {
        let step = ShowStepAction(title: "Open the lid", index: 1, total: 2, detail: "It is stiff the first time")
        XCTAssertEqual(
            try ActionPerformer.narration(for: step),
            "Step 1 of 2. Open the lid. It is stiff the first time."
        )
    }

    func testBlankDetailIsNotAppended() throws {
        let step = ShowStepAction(title: "Open the lid", index: 1, total: 2, detail: "   ")
        XCTAssertEqual(try ActionPerformer.narration(for: step), "Step 1 of 2. Open the lid.")
    }

    func testImpossibleStepNumbersAreRefused() {
        for (index, total) in [(0, 3), (4, 3), (1, 0), (-1, 5)] {
            XCTAssertThrowsError(
                try ActionPerformer.narration(for: ShowStepAction(title: "x", index: index, total: total)),
                "step \(index) of \(total) should be refused"
            )
        }
    }

    // MARK: performing

    func testPerformingSayPassesTheToneThrough() async throws {
        let speaker = RecordingSpeaker()
        let performer = ActionPerformer(speaker: speaker, urlOpener: RecordingUrlOpener())

        try await performer.perform(.say(SayAction(text: "hello", tone: .calm)))

        XCTAssertEqual(speaker.lines, [.init(text: "hello", tone: .calm)])
    }

    func testPerformingAStepNarratesItEncouragingly() async throws {
        let speaker = RecordingSpeaker()
        let performer = ActionPerformer(speaker: speaker, urlOpener: RecordingUrlOpener())

        try await performer.perform(.showStep(ShowStepAction(title: "Try it", index: 1, total: 1)))

        XCTAssertEqual(speaker.lines.count, 1)
        XCTAssertEqual(speaker.lines.first?.text, "Step 1 of 1. Try it.")
        XCTAssertEqual(speaker.lines.first?.tone, .encouraging)
    }

    func testARefusedUrlIsNeverHandedToTheOpener() async {
        let opener = RecordingUrlOpener()
        let performer = ActionPerformer(speaker: RecordingSpeaker(), urlOpener: opener)

        do {
            try await performer.perform(.openUrl(OpenUrlAction(url: "file:///etc/passwd")))
            XCTFail("a file: URL should not have been performed")
        } catch {
            // expected
        }
        XCTAssertTrue(opener.opened.isEmpty, "nothing should reach the opener")
    }
}

final class ConfigurationTests: XCTestCase {

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shell.json")
    }

    func testMissingConfigIsNotAnErrorAndYieldsTheHostedDefault() throws {
        let configuration = try ConfigurationStore.load(from: temporaryConfigURL())
        XCTAssertNil(configuration.token)
        XCTAssertEqual(configuration.resolvedBaseURL, SaathiBackend.defaultBaseURL)
    }

    func testAConfiguredBackendUrlOverridesTheDefault() {
        let configuration = SaathiConfiguration(backendUrl: "http://localhost:8080", token: "t")
        XCTAssertEqual(configuration.resolvedBaseURL, "http://localhost:8080")
    }

    func testABlankBackendUrlFallsBackToTheDefault() {
        XCTAssertEqual(
            SaathiConfiguration(backendUrl: "   ").resolvedBaseURL,
            SaathiBackend.defaultBaseURL
        )
    }

    /// The file holds a bearer token. A token in a world-readable file is a token every process on
    /// the machine has.
    func testTheConfigIsWrittenOwnerReadableOnly() throws {
        let url = temporaryConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ConfigurationStore.save(SaathiConfiguration(token: "secret"), to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600, "shell.json must be 0600, was \(String(permissions ?? -1, radix: 8))")
    }

    func testASavedConfigLoadsBackIdentically() throws {
        let url = temporaryConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = SaathiConfiguration(backendUrl: "https://example.test", token: "abc")
        try ConfigurationStore.save(original, to: url)
        let loaded = try ConfigurationStore.load(from: url)

        XCTAssertEqual(loaded.backendUrl, original.backendUrl)
        XCTAssertEqual(loaded.token, original.token)
    }

    func testMalformedConfigSaysSoRatherThanPretendingItIsEmpty() throws {
        let url = temporaryConfigURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json".utf8).write(to: url)

        XCTAssertThrowsError(try ConfigurationStore.load(from: url)) { error in
            guard case ConfigurationError.malformed = error else {
                return XCTFail("expected a malformed-config error, got \(error)")
            }
        }
    }

    func testTheConfigPathCanBeOverriddenForTestsAndCI() {
        let url = ConfigurationStore.defaultPath(
            environment: ["SAATHI_CONFIG": "/tmp/elsewhere.json"],
            homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )
        XCTAssertEqual(url.path, "/tmp/elsewhere.json")
    }

    func testTheDefaultPathIsUnderTheHomeDirectory() {
        let url = ConfigurationStore.defaultPath(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )
        XCTAssertEqual(url.path, "/Users/nobody/.saathi/shell.json")
    }
}

final class ContractTests: XCTestCase {

    /// The generated contract is the only thing binding this client to the Windows one. If a wire
    /// name changes here without changing there, nothing else in either build would notice.
    func testWireNamesAreWhatTheSchemaSays() {
        XCTAssertEqual(SaathiAction.allWireNames, ["say", "show_step", "open_url"])
        XCTAssertEqual(SayAction.wireName, "say")
        XCTAssertEqual(ShowStepAction.wireName, "show_step")
        XCTAssertEqual(OpenUrlAction.wireName, "open_url")
    }

    func testAnActionReportsItsOwnWireName() {
        XCTAssertEqual(SaathiAction.say(SayAction(text: "x")).wireName, "say")
        XCTAssertEqual(
            SaathiAction.showStep(ShowStepAction(title: "x", index: 1, total: 1)).wireName,
            "show_step"
        )
    }

    func testEnumsRoundTripThroughTheirWireValues() throws {
        for tone in Tone.allCases {
            let encoded = try JSONEncoder().encode(tone)
            XCTAssertEqual(try JSONDecoder().decode(Tone.self, from: encoded), tone)
        }
        XCTAssertEqual(Tone(rawValue: "calm"), .calm)
        XCTAssertNil(Tone(rawValue: "excited"), "the enum is closed on purpose")
    }

    func testDefaultsMatchTheSchema() {
        XCTAssertEqual(SayAction(text: "x").tone, .neutral)
        XCTAssertEqual(ShowStepAction(title: "x", index: 1, total: 1).pace, .normal)
    }
}
