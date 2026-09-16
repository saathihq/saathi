//
//  SetupPlanTests.swift
//  SaathiKitTests
//
//  "It figures it out for me" is a promise that has to be checkable without a network, a window or
//  a key. That is the entire reason SetupPlan is a value type rather than a method on the panel.
//

import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class SetupPlanTests: XCTestCase {

    func testAnOpenAIKeyBuysTheRealtimeLane() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.lane, .realtime)
        XCTAssertEqual(plan.voiceModel, "gpt-realtime")
        XCTAssertEqual(plan.model, "gpt-4o-mini")
        XCTAssertTrue(plan.storedButUnused.isEmpty)
    }

    /// The honest bit. Both keys given, only one used — and the plan says which, so the panel can
    /// tell the truth instead of letting someone believe Claude is in the loop.
    func testBothKeysStillMeansOpenAIAndSaysTheOtherIsUnused() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.storedButUnused, [.anthropic])
    }

    func testAnthropicAloneGetsTheChainLane() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: true)
        XCTAssertEqual(plan.provider, .anthropic)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "claude-sonnet-5")
        XCTAssertTrue(plan.voiceModel.isEmpty, "the chain lane opens no socket")
        XCTAssertTrue(plan.storedButUnused.isEmpty, "the key it has is the key it uses")
    }

    func testNoKeysFallsBackToWhateverIsOnThisMachine() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false)
        XCTAssertEqual(plan.provider, .local)
        XCTAssertEqual(plan.lane, .chain)
    }

    /// Every branch has to produce a sentence. An empty explanation would render as a blank line in
    /// the panel, which reads as a bug rather than as a default.
    func testEveryPlanExplainsItself() {
        for openAI in [true, false] {
            for anthropic in [true, false] {
                let plan = SetupPlan.make(openAIKeyValid: openAI, anthropicKeyValid: anthropic)
                XCTAssertFalse(
                    plan.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "no explanation for openAI=\(openAI) anthropic=\(anthropic)")
            }
        }
    }

    /// The local explanation is the one a stuck person reads most, so it has to name the thing they
    /// are missing rather than say "not configured".
    func testTheLocalExplanationNamesWhatToInstall() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false)
        XCTAssertTrue(plan.explanation.contains("Ollama"))
    }

    func testTheRealtimeExplanationSaysWhereTheVoiceGoes() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertTrue(plan.explanation.lowercased().contains("openai"))
        XCTAssertTrue(plan.explanation.lowercased().contains("voice"))
    }

    // MARK: applying a plan

    func testApplyingAPlanWritesBothKeysAndTheChosenProvider() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let config = plan.applied(to: SaathiConfiguration(), openAIKey: "sk-o", anthropicKey: "sk-a")

        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertEqual(config.anthropicKey, "sk-a", "an unused key is still stored")
        XCTAssertEqual(config.voiceModel, "gpt-realtime")
        XCTAssertEqual(config.credential(for: .openai), "sk-o")
    }

    /// Settings a person chose by hand are not ours to throw away because they pasted a key.
    func testApplyingAPlanKeepsUnrelatedSettings() {
        let existing = SaathiConfiguration(backendUrl: "https://example.test", token: "tok")
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        let config = plan.applied(to: existing, openAIKey: "sk-o", anthropicKey: "")

        XCTAssertEqual(config.backendUrl, "https://example.test")
        XCTAssertEqual(config.token, "tok")
    }

    /// A key that did not validate is not saved. Storing a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working.
    func testAKeyThatDidNotValidateIsNotStored() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        let config = plan.applied(to: SaathiConfiguration(), openAIKey: "sk-o", anthropicKey: "sk-bad")
        XCTAssertNil(config.anthropicKey)
    }

    /// Keys pasted from many sources arrive with trailing whitespace or newlines. Trimming is
    /// non-negotiable; if skipped, the key is refused as malformed on the next launch, which looks
    /// like the key suddenly stopped working.
    func testAKeyWithLeadingTrailingWhitespaceIsTrimmedBeforeStorage() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let config = plan.applied(
            to: SaathiConfiguration(),
            openAIKey: "  sk-o  \n",
            anthropicKey: "  sk-a  \n"
        )

        XCTAssertEqual(config.openaiKey, "sk-o", "leading and trailing whitespace must be trimmed")
        XCTAssertEqual(
            config.anthropicKey,
            "sk-a",
            "unused key is still stored, also trimmed"
        )
    }

    /// A key that is only whitespace is not stored as an empty string — it is not stored at all.
    /// Empty strings would be indistinguishable from "not present" and would clutter config.
    func testAWhitespaceOnlyKeyIsStoredAsNilNotEmptyString() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let config = plan.applied(
            to: SaathiConfiguration(),
            openAIKey: "sk-o",
            anthropicKey: "   \n\t   "
        )

        XCTAssertEqual(
            config.openaiKey,
            "sk-o"
        )
        XCTAssertNil(config.anthropicKey, "whitespace-only key becomes nil, not empty string")
    }

    /// When a key did not validate, an existing stored key for that provider is kept — it was
    /// good once. Clearing it would erase a working credential just because this attempt failed,
    /// which is worse than keeping a stale one that the user can see and update.
    func testAnExistingKeyIsPreservedWhenNewAttemptDidNotValidate() {
        let existing = SaathiConfiguration(anthropicKey: "sk-a-old")
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false)
        let config = plan.applied(to: existing, openAIKey: "", anthropicKey: "sk-a-bad")

        XCTAssertEqual(config.anthropicKey, "sk-a-old", "existing valid key preserved when new attempt fails")
    }
}
