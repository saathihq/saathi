//
//  IslandModelTests.swift
//  SaathiShellTests
//
//  The Home panel's model, checked without a window, a menu or a voice session behind it.
//

import XCTest
import SaathiContract
import SaathiKit
@testable import SaathiShell

@MainActor
final class IslandModelTests: XCTestCase {

    func testDefaultsAreReadyAndUnconfigured() {
        let model = IslandModel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.providerTitle, "")
        XCTAssertEqual(model.privacyLine, "")
        XCTAssertTrue(model.permissions.isEmpty)
        XCTAssertTrue(model.companionVisible)
    }

    func testThePermissionsMapUpdates() {
        let model = IslandModel()
        model.permissions = [.microphone: .granted, .inputMonitoring: .notDetermined]
        XCTAssertEqual(model.permissions[.microphone], .granted)
        XCTAssertEqual(model.permissions[.inputMonitoring], .notDetermined)
        XCTAssertNil(model.permissions[.speechRecognition])
    }

    func testActionsDefaultToDoingNothing() {
        // Every closure has a harmless default, so a panel built before the shell wires it up
        // doesn't crash if something is clicked.
        let actions = IslandActions()
        actions.onTalk()
        actions.onProvider()
        actions.onFixPermission(.microphone)
        actions.onToggleCompanion()
        actions.onQuit()
    }
}

// MARK: - The Setup tab's model

@MainActor
final class IslandSetupModelTests: XCTestCase {

    func testTheIslandStartsOnHome() {
        XCTAssertEqual(IslandModel().tab, .home)
        XCTAssertEqual(IslandModel().keyStates, KeyStates())
        XCTAssertEqual(IslandModel().planExplanation, "")
        XCTAssertEqual(IslandModel().keysNote, "")
        XCTAssertEqual(IslandModel().provider, .local)
        XCTAssertTrue(IslandModel().providerChoices.isEmpty, "nothing to pick until the shell says what there is")
        XCTAssertFalse(IslandModel().sarvamSpeechOn)
        XCTAssertFalse(IslandModel().sarvamSpeechAvailable)
    }

    func testTheTabSwitches() {
        let model = IslandModel()
        model.tab = .setup
        XCTAssertEqual(model.tab, .setup)
    }

    /// A key is shown, never re-shown in full. Four trailing characters is enough to tell two keys
    /// apart and not enough to be a credential.
    func testASavedKeyIsMaskedToItsLastFourCharacters() {
        XCTAssertEqual(IslandModel.masked("sk-proj-abcdefghijkl"), "sk-…ijkl")
        XCTAssertEqual(IslandModel.masked("sk-ant-api03-zzzz9999"), "sk-…9999")
    }

    /// A short or malformed key must not be echoed back in full by the masking itself.
    func testMaskingNeverEchoesAShortKey() {
        XCTAssertEqual(IslandModel.masked("abc"), "sk-…")
        XCTAssertEqual(IslandModel.masked(""), "sk-…")
    }

    func testAFieldCanBeCheckingAndThenChecked() {
        let model = IslandModel()
        model.keyStates[.openai] = .checking
        XCTAssertEqual(model.keyStates.openAI, .checking)
        model.keyStates[.openai] = .checked(.rejected("OpenAI did not accept that key."))
        XCTAssertEqual(model.keyStates[.openai], .checked(.rejected("OpenAI did not accept that key.")))
    }

    /// Three fields, reached by vendor so that nothing has to be written out three times. A
    /// provider that takes no key has no field to be in any state.
    func testEachVendorHasItsOwnFieldAndNothingElseHasOne() {
        var states = KeyStates()
        states[.sarvam] = .checking
        states[.anthropic] = .saved(masked: "sk-…abcd")
        states[.local] = .checking
        states[.hosted] = .checking
        XCTAssertEqual(states, KeyStates(sarvam: .checking, anthropic: .saved(masked: "sk-…abcd")))
        XCTAssertEqual(SetupPlan.vendors.map { states[$0] }, [.empty, .checking, .saved(masked: "sk-…abcd")])
        XCTAssertEqual(states[.local], .empty)
    }

    /// Sarvam speaks Gujarati and Punjabi, so they can be chosen. The tags are the ones Sarvam's
    /// own codes are made from.
    func testTheLanguagesOnOfferIncludeEveryOneSarvamSpeaksButOdia() {
        let tags = Set(IslandLanguage.all.map(\.tag))
        for tag in ["en", "hi", "ta", "te", "bn", "mr", "kn", "ml", "gu", "pa"] {
            XCTAssertTrue(tags.contains(tag), tag)
            XCTAssertNotNil(SarvamLanguage.code(for: tag), tag)
        }
        XCTAssertEqual(IslandLanguage.all.count, tags.count, "a tag offered twice")
    }

    /// The button must be inert while a check is in flight, or a double-click fires two round trips
    /// and the second answer overwrites the first.
    func testAFieldIsBusyOnlyWhileChecking() {
        XCTAssertTrue(KeyFieldState.checking.isBusy)
        XCTAssertFalse(KeyFieldState.empty.isBusy)
        XCTAssertFalse(KeyFieldState.editing.isBusy)
        XCTAssertFalse(KeyFieldState.checked(.valid).isBusy)
        XCTAssertFalse(KeyFieldState.saved(masked: "sk-…abcd").isBusy)
    }

    /// Only a validated key may be saved. Without this the panel would happily bank a key the vendor
    /// refused a second ago.
    func testOnlyACheckedValidFieldCountsAsValid() {
        XCTAssertTrue(KeyFieldState.checked(.valid).isValid)
        XCTAssertTrue(KeyFieldState.saved(masked: "sk-…abcd").isValid)
        XCTAssertFalse(KeyFieldState.checked(.rejected("no")).isValid)
        XCTAssertFalse(KeyFieldState.checked(.unreachable("offline")).isValid)
        XCTAssertFalse(KeyFieldState.empty.isValid)
        XCTAssertFalse(KeyFieldState.editing.isValid)
    }

    func testTheActionsDefaultToDoingNothing() {
        let actions = IslandActions()
        actions.onKeyFields(VendorKeys(openAI: "sk-o"), .openai)
        actions.onKeyFields(VendorKeys(), nil)
        actions.onSaveKeys(VendorKeys(openAI: "sk-o", sarvam: "sk-s", anthropic: "sk-a"))
        actions.onChooseProvider(.sarvam)
        actions.onSarvamSpeech(true)
        actions.onLanguage("ml")
    }
}

// MARK: - The sentence under the fields, and the save it promises

/// The invariant these cover: the plan the panel describes is the plan Save would produce. Both
/// used to be computed separately, from different inputs, and the two answers could disagree about
/// where someone's voice was going.
@MainActor
final class SetupDecisionTests: XCTestCase {

    private func decide(
        fields: VendorKeys = VendorKeys(),
        states: KeyStates = KeyStates(),
        configuration: SaathiConfiguration = SaathiConfiguration()
    ) -> AppController.SetupDecision {
        AppController.setupDecision(fields: fields, states: states, configuration: configuration)
    }

    /// The regression, exactly as it happened: a fresh install, an OpenAI key checked, then an
    /// Anthropic key checked. Judging OpenAI against an empty string flipped the plan to Anthropic
    /// and the panel said "your voice stays here" — while Save, which saw both fields, sent audio
    /// to OpenAI. Both keys are live in the panel, so both must count in the preview.
    func testTwoCheckedKeysOnAFreshInstallStillChooseOpenAI() {
        let decision = decide(
            fields: VendorKeys(openAI: "sk-o", anthropic: "sk-a"),
            states: KeyStates(openAI: .checked(.valid), anthropic: .checked(.valid)))
        XCTAssertEqual(decision.plan.provider, .openai)
        XCTAssertTrue(
            decision.plan.explanation.contains("leaves this machine"),
            "the sentence must not promise the voice stays here: \(decision.plan.explanation)")
        XCTAssertEqual(decision.plan.eye, .anthropic)
        XCTAssertTrue(decision.plan.storedButUnused.isEmpty, "the Anthropic key looks at the screen")
        XCTAssertEqual(decision.keys, VendorKeys(openAI: "sk-o", anthropic: "sk-a"))
    }

    /// The sentence and the file, checked against each other across every combination of verdicts
    /// and fields, for three vendors and for configurations that already ask for Sarvam's speech:
    /// the sentence says the voice leaves as audio exactly when the configuration Save would write
    /// sends it, names Sarvam exactly when Sarvam is where it goes, and never names a vendor there
    /// is no key for. This is the invariant itself, not the code path that happens to implement it.
    func testTheSentenceAlwaysDescribesTheConfigurationSaveWouldWrite() {
        let states: [KeyFieldState] = [
            .empty, .editing, .checking, .checked(.valid), .checked(.rejected("no")),
            .checked(.unreachable("offline")), .saved(masked: "sk-…abcd"),
        ]
        // Empty, or a key as it is pasted. A field of nothing but spaces is an empty field, which
        // `testAFieldOfWhitespaceIsNotATypedKey` pins on its own; leaving it out of the sweep keeps
        // this at forty thousand cases rather than a hundred and forty.
        let fields = ["", " sk-typed \n"]
        let configurations = [
            SaathiConfiguration(),
            SaathiConfiguration(provider: .local),
            SaathiConfiguration(provider: .openai, apiKey: "sk-legacy"),
            SaathiConfiguration(provider: .anthropic, apiKey: "sk-legacy"),
            SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy"),
            SaathiConfiguration(provider: .openai, openaiKey: "sk-stored-o"),
            SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-stored-a"),
            SaathiConfiguration(provider: .openai, openaiKey: "sk-stored-o", anthropicKey: "sk-stored-a"),
            SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-stored-s"),
            SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-stored-s", speech: .sarvam),
            SaathiConfiguration(
                provider: .sarvam, openaiKey: "sk-stored-o", anthropicKey: "sk-stored-a", sarvamKey: "sk-stored-s",
                speech: .sarvam),
            SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-stored-a", sarvamKey: "sk-stored-s", speech: .sarvam),
            SaathiConfiguration(sarvamKey: "sk-stored-s", speech: .sarvam),
            SaathiConfiguration(provider: .local, speech: .sarvam),
            SaathiConfiguration(provider: .hosted, sarvamKey: "sk-stored-s", token: "tok"),
        ]
        var checked = 0
        for configuration in configurations {
            for openAI in states {
                for sarvam in states {
                    for anthropic in states {
                        for openAIField in fields {
                            for sarvamField in fields {
                                for anthropicField in fields {
                                    let decision = decide(
                                        fields: VendorKeys(openAI: openAIField, sarvam: sarvamField, anthropic: anthropicField),
                                        states: KeyStates(openAI: openAI, sarvam: sarvam, anthropic: anthropic),
                                        configuration: configuration)
                                    let written = decision.plan.applied(to: configuration, keys: decision.keys)
                                    let sentence = decision.plan.explanation
                                    let toSarvam = SarvamSpeech.isOn(written)
                                    let leaves = written.providerRow.voice == .realtime || toSarvam
                                    checked += 1
                                    // One comparison a case and one failure at most: a hundred
                                    // thousand passing assertions are slower than the code under test.
                                    let holds = written.provider == decision.plan.provider
                                        && sentence.contains("leaves this machine as audio") == leaves
                                        && sentence.contains("straight to Sarvam") == toSarvam
                                        && sentence.contains("straight to OpenAI") == (written.provider == .openai)
                                        && (!toSarvam || written.credential(for: .sarvam) != nil)
                                        && (written.provider != .openai || written.credential(for: .openai) != nil)
                                    // And the sentence on show while keys are still being
                                    // typed is about the plan Save produces once they are accepted.
                                    let typed = AppController.typed(
                                        in: VendorKeys(openAI: openAIField, sarvam: sarvamField, anthropic: anthropicField))
                                    var accepted = KeyStates(openAI: openAI, sarvam: sarvam, anthropic: anthropic)
                                    for kind in typed { accepted[kind] = .checked(.valid) }
                                    let preview = AppController.setupPreview(
                                        typed: typed, states: KeyStates(openAI: openAI, sarvam: sarvam, anthropic: anthropic),
                                        configuration: configuration)
                                    let onceAccepted = AppController.setupPlan(
                                        typed: typed, states: accepted, configuration: configuration)
                                    guard preview.plan == onceAccepted, preview.sentence.hasSuffix(onceAccepted.explanation) else {
                                        return XCTFail("the preview is not what Save would do: \(preview.sentence) vs \(onceAccepted.explanation)")
                                    }
                                    guard holds else {
                                        return XCTFail("""
                                            the sentence and the save disagree.
                                            sentence: \(sentence)
                                            written:  provider \(String(describing: written.provider)), \
                                            speech \(String(describing: written.speech)), leaves \(leaves)
                                            from:     \(configuration)
                                            fields:   \([openAIField, sarvamField, anthropicField])
                                            states:   \([openAI, sarvam, anthropic])
                                            """)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, configurations.count * 343 * 8)
    }

    /// A Sarvam key pasted into a working OpenAI install moves Saathi to Sarvam — otherwise the key
    /// just added would do nothing anyone could see — and the sentence says where the voice will go
    /// before it is saved.
    func testPastingASarvamKeyMovesToSarvamAndSaysWhereTheVoiceGoes() {
        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        let decision = decide(
            fields: VendorKeys(sarvam: " sk-s \n"),
            states: KeyStates(openAI: .saved(masked: "sk-…sk-o"), sarvam: .checked(.valid)),
            configuration: existing)
        XCTAssertEqual(decision.plan.provider, .sarvam)
        XCTAssertEqual(decision.plan.speech, .sarvam)
        XCTAssertTrue(decision.plan.explanation.contains("straight to Sarvam"), decision.plan.explanation)

        let written = decision.plan.applied(to: existing, keys: decision.keys)
        XCTAssertTrue(SarvamSpeech.isOn(written))
        XCTAssertEqual(written.sarvamKey, "sk-s")
        XCTAssertEqual(written.openaiKey, "sk-o", "kept: it looks at the screen, and the picker goes back to it")
        XCTAssertEqual(written.model, "sarvam-105b")
    }

    /// Until the vendor has accepted it, a key in a field decides nothing.
    func testASarvamKeyStillBeingTypedChangesNothing() {
        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        for state in [KeyFieldState.editing, .checking, .checked(.rejected("Sarvam did not accept that key."))] {
            let decision = decide(
                fields: VendorKeys(sarvam: "sk-s"),
                states: KeyStates(openAI: .saved(masked: "sk-…sk-o"), sarvam: state),
                configuration: existing)
            XCTAssertEqual(decision.plan.provider, .openai, "\(state)")
            XCTAssertFalse(decision.plan.explanation.contains("Sarvam"), "\(state)")
        }
    }

    /// `provider: sarvam` with the legacy key has always listened on this Mac and sent only the
    /// words. Pasting an Anthropic key is not asking for that to change, and it does not.
    func testAnUnrelatedSaveDoesNotStartSendingTheVoiceToSarvam() {
        let thinkingOnly = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
        var states = AppController.seededKeyStates(for: thinkingOnly)
        states.anthropic = .checked(.valid)
        let decision = decide(fields: VendorKeys(anthropic: "sk-a"), states: states, configuration: thinkingOnly)
        XCTAssertEqual(decision.plan.provider, .sarvam)
        XCTAssertEqual(decision.plan.speech, .device)
        XCTAssertTrue(decision.plan.explanation.contains("Your voice stays here"), decision.plan.explanation)

        let written = decision.plan.applied(to: thinkingOnly, keys: decision.keys)
        XCTAssertFalse(SarvamSpeech.isOn(written))
        XCTAssertEqual(written.anthropicKey, "sk-a")
        XCTAssertEqual(written.sarvamKey, "sk-legacy", "the shared key is filed under the vendor it was used for")
        XCTAssertNil(written.openaiKey)
    }

    /// Claude thinking with Sarvam's ears, made with the switch: a Save about something else
    /// describes it and leaves it as it is.
    func testSarvamsEarsInFrontOfClaudeSurviveASave() {
        let mixed = SaathiConfiguration(
            provider: .anthropic, anthropicKey: "sk-a", sarvamKey: "sk-s", speech: .sarvam)
        var states = AppController.seededKeyStates(for: mixed)
        states.anthropic = .checked(.valid)
        let decision = decide(fields: VendorKeys(anthropic: "sk-a-new"), states: states, configuration: mixed)
        XCTAssertEqual(decision.plan.provider, .anthropic)
        XCTAssertEqual(decision.plan.speech, .sarvam)
        XCTAssertTrue(decision.plan.explanation.contains("straight to Sarvam"), decision.plan.explanation)
        let written = decision.plan.applied(to: mixed, keys: decision.keys)
        XCTAssertTrue(SarvamSpeech.isOn(written))
        XCTAssertEqual(written.anthropicKey, "sk-a-new")
    }

    /// A legacy config holds one shared `apiKey` and no vendor key. Reading the vendor fields
    /// directly made both effective keys empty, so Save produced the local plan and demoted a
    /// working install to "look for Ollama". `credential(for:)` is what everything else asks.
    func testALegacyApiKeyCountsAsTheKeyItIs() {
        let legacy = SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-key")
        let decision = decide(states: KeyStates(openAI: .saved(masked: "sk-…y")), configuration: legacy)
        XCTAssertEqual(decision.keys.openAI, "sk-legacy-key")
        XCTAssertEqual(decision.plan.provider, .openai, "a legacy key must not be demoted to local")
    }

    /// Nothing typed and nothing stored is genuinely no key, however confident the verdict is.
    func testAValidVerdictWithNoKeyBehindItCountsForNothing() {
        let decision = decide(
            states: KeyStates(openAI: .checked(.valid), sarvam: .checked(.valid), anthropic: .checked(.valid)))
        XCTAssertEqual(decision.plan.provider, .local)
    }

    /// Typing invalidates the verdict, and an invalidated verdict must not keep its key in play.
    func testAnEditedFieldDropsOutOfThePlan() {
        let decision = decide(
            fields: VendorKeys(openAI: "sk-o-half-typed", anthropic: "sk-a"),
            states: KeyStates(openAI: .editing, anthropic: .checked(.valid)))
        XCTAssertEqual(decision.plan.provider, .anthropic)
    }
}

// MARK: - What is shown while a key is being typed

/// Save checks whatever was typed and saves it in the same breath, so by the time a key has a
/// verdict it has been saved. The sentence under the fields therefore describes what Save is about
/// to do, as an "if" — someone pasting a key reads where their voice would go before they press
/// Save, not in the instant after.
@MainActor
final class SetupPreviewTests: XCTestCase {

    private let onOpenAI = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
    private var seeded: KeyStates { AppController.seededKeyStates(for: onOpenAI) }

    func testAKeyBeingTypedIsShownAsWhatSaveWouldDoIfItIsAccepted() {
        var states = seeded
        states.sarvam = .editing
        let preview = AppController.setupPreview(typed: [.sarvam], states: states, configuration: onOpenAI)
        XCTAssertEqual(preview.plan.provider, .sarvam)
        XCTAssertEqual(preview.plan.speech, .sarvam)
        XCTAssertEqual(
            preview.sentence,
            "If Sarvam accepts this key: I will listen, think and speak through Sarvam, in the language "
                + "chosen below. Your voice leaves this machine as audio, straight to Sarvam — Saathi's "
                + "servers are not in the conversation.")
    }

    /// A key Save would check again is still an "if", whatever was said about it last time.
    func testAKeyThatWasRefusedOrIsBeingCheckedIsStillAnIf() {
        for state in [KeyFieldState.checking, .checked(.rejected("no")), .checked(.unreachable("offline")), .empty] {
            var states = seeded
            states.sarvam = state
            let preview = AppController.setupPreview(typed: [.sarvam], states: states, configuration: onOpenAI)
            XCTAssertTrue(preview.sentence.hasPrefix("If Sarvam accepts this key: "), "\(state): \(preview.sentence)")
        }
    }

    func testWithNothingBeingTypedTheSentenceIsThePlanAsItStands() {
        let preview = AppController.setupPreview(typed: [], states: seeded, configuration: onOpenAI)
        XCTAssertEqual(preview.plan.provider, .openai)
        XCTAssertEqual(preview.sentence, preview.plan.explanation)
        XCTAssertFalse(preview.sentence.hasPrefix("If"))
    }

    /// Once the vendor has accepted it there is no "if" left — this is the sentence on show in the
    /// moment between the check landing and the save.
    func testAKeyAlreadyAcceptedIsNotAnIf() {
        var states = seeded
        states.sarvam = .checked(.valid)
        let preview = AppController.setupPreview(typed: [.sarvam], states: states, configuration: onOpenAI)
        XCTAssertEqual(preview.plan.provider, .sarvam)
        XCTAssertEqual(preview.sentence, preview.plan.explanation)
    }

    func testSeveralKeysBeingTypedAreNamedTogether() {
        let fresh = SaathiConfiguration()
        let two = AppController.setupPreview(
            typed: [.openai, .anthropic], states: KeyStates(openAI: .editing, anthropic: .editing), configuration: fresh)
        XCTAssertTrue(two.sentence.hasPrefix("If OpenAI and Anthropic accept these keys: I will talk with you through OpenAI"), two.sentence)

        let three = AppController.setupPreview(
            typed: [.openai, .sarvam, .anthropic],
            states: KeyStates(openAI: .editing, sarvam: .checked(.valid), anthropic: .editing), configuration: fresh)
        XCTAssertTrue(three.sentence.hasPrefix("If OpenAI and Anthropic accept these keys: "), "only the ones still to be accepted: \(three.sentence)")

        let all = AppController.setupPreview(
            typed: [.openai, .sarvam, .anthropic], states: KeyStates(), configuration: fresh)
        XCTAssertTrue(all.sentence.hasPrefix("If OpenAI, Sarvam and Anthropic accept these keys: "), all.sentence)
    }

    /// An Anthropic key on its own changes nothing about where the conversation goes, and the
    /// sentence says so by not changing — apart from the "if".
    func testAnAnthropicKeyBeingTypedLeavesTheConversationWhereItIs() {
        var states = seeded
        states.anthropic = .editing
        let preview = AppController.setupPreview(typed: [.anthropic], states: states, configuration: onOpenAI)
        XCTAssertEqual(preview.plan.provider, .openai)
        XCTAssertEqual(preview.plan.eye, .anthropic)
        XCTAssertTrue(preview.sentence.hasPrefix("If Anthropic accepts this key: I will talk with you through OpenAI"), preview.sentence)
    }
}

// MARK: - What Setup opens showing

@MainActor
final class SeededKeyStateTests: XCTestCase {

    func testAVendorKeySeedsItsOwnVendorOnly() {
        let seeded = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .openai, openaiKey: "sk-openai-1234"))
        XCTAssertEqual(seeded.openAI, .saved(masked: "sk-…1234"))
        XCTAssertEqual(seeded.anthropic, .empty, "no Anthropic key is stored, so none may be shown")
        XCTAssertEqual(seeded.sarvam, .empty)
    }

    func testASarvamKeySeedsTheSarvamField() {
        let seeded = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam-4321"))
        XCTAssertEqual(seeded, KeyStates(sarvam: .saved(masked: "sk-…4321")))

        // And the key Sarvam was given before it had a field of its own.
        let legacy = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy-1234"))
        XCTAssertEqual(legacy, KeyStates(sarvam: .saved(masked: "sk-…1234")))
    }

    func testBothVendorKeysSeedBothFields() {
        let seeded = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .openai, openaiKey: "sk-openai-1234", anthropicKey: "sk-ant-5678"))
        XCTAssertEqual(seeded.openAI, .saved(masked: "sk-…1234"))
        XCTAssertEqual(seeded.anthropic, .saved(masked: "sk-…5678"))
    }

    /// The regression: `credential(for:)` hands the legacy shared key to both vendors, so seeding
    /// from it showed the key masked under Anthropic on a config that never mentioned Anthropic —
    /// and lit up Save with two empty fields. It seeds only the vendor the config names.
    func testALegacyKeySeedsOnlyTheProviderTheConfigNames() {
        let seeded = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-1234"))
        XCTAssertEqual(seeded, KeyStates(openAI: .saved(masked: "sk-…1234")))

        let anthropic = AppController.seededKeyStates(
            for: SaathiConfiguration(provider: .anthropic, apiKey: "sk-legacy-1234"))
        XCTAssertEqual(anthropic.openAI, .empty)
        XCTAssertEqual(anthropic.anthropic, .saved(masked: "sk-…1234"))
    }

    /// A legacy key with no provider named says nothing about whose key it is. Claiming it for
    /// either vendor would be the panel inventing a fact the file does not hold.
    func testALegacyKeyWithNoProviderNamedSeedsNothing() {
        let seeded = AppController.seededKeyStates(for: SaathiConfiguration(apiKey: "sk-legacy-1234"))
        XCTAssertEqual(seeded, KeyStates())
    }

    func testAnEmptyConfigSeedsNothing() {
        XCTAssertEqual(AppController.seededKeyStates(for: SaathiConfiguration()), KeyStates())
    }

    /// Seeding and deciding must read the same config the same way, or Setup opens showing a key
    /// the plan does not count — which is the same class of lie by a different route.
    func testWhatIsSeededIsWhatSaveWouldUse() {
        let legacy = SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-1234")
        let seeded = AppController.seededKeyStates(for: legacy)
        let decision = AppController.setupDecision(fields: VendorKeys(), states: seeded, configuration: legacy)
        XCTAssertEqual(decision.plan.provider, .openai)
        XCTAssertEqual(decision.keys.openAI, "sk-legacy-1234")
        // `credential(for:)` still hands the legacy key to the other two vendors, but with no
        // verdict behind it nothing counts it, and the config Save would write gains no key of theirs.
        let written = decision.plan.applied(to: legacy, keys: decision.keys)
        XCTAssertEqual(written.openaiKey, "sk-legacy-1234")
        XCTAssertNil(written.anthropicKey, "the legacy key must not be re-filed as an Anthropic key")
        XCTAssertNil(written.sarvamKey, "nor as a Sarvam one")
    }
}

// MARK: - What the panel says after a save

@MainActor
final class SetupPresentationTests: XCTestCase {

    /// It said "Anthropic key saved. Nothing uses it yet." about the key `ScreenSight` prefers.
    func testTheNoteSaysWhatTheAnthropicKeyIsFor() {
        let plan = SetupPlan.make(valid: [.openai, .anthropic])
        XCTAssertEqual(
            AppController.keysNote(for: plan, language: "en"),
            "The Anthropic key looks at the screen when you ask about something on it.")
    }

    /// A key that really is doing nothing is named, with the way to put it to use.
    func testAKeyNothingUsesIsNamedAndSoIsTheWayToUseIt() {
        let plan = SetupPlan.make(valid: [.openai, .sarvam])
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(
            AppController.keysNote(for: plan, language: "en"),
            "The Sarvam key is saved and not in use. Choose Sarvam under Where it thinks to use it.")
    }

    func testThereIsNoNoteWhenThereIsNothingToAdd() {
        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: [.openai]), language: "en"), "")
        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: []), language: "en"), "")
        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: [.anthropic]), language: "en"), "")
    }

    /// Sarvam does not look at screens. Someone with only its key is told what would.
    func testSarvamAloneSaysNothingHereCanLook() {
        XCTAssertEqual(
            AppController.keysNote(for: SetupPlan.make(valid: [.sarvam]), language: "ml"),
            "Nothing here can look at the screen: that takes an OpenAI or an Anthropic key.")
    }

    /// The session would refuse to start, and the sentence above promises Sarvam will listen "in
    /// the language chosen below" — so what is wrong with that language is said before the save.
    func testALanguageSarvamDoesNotSpeakIsSaidBeforeItIsSaved() {
        let plan = SetupPlan.make(valid: [.sarvam, .anthropic], typed: [.sarvam])
        XCTAssertEqual(
            AppController.keysNote(for: plan, language: "fr"),
            "Sarvam does not hear or speak French. Choose another language under Voice first. "
                + "The Anthropic key looks at the screen when you ask about something on it.")
        XCTAssertFalse(AppController.keysNote(for: plan, language: "ml").contains("does not hear"))
        XCTAssertFalse(AppController.keysNote(for: plan, language: "or").contains("does not hear"), "Odia is od-IN to Sarvam")

        // Sarvam only thinking listens on this Mac, so Sarvam's languages are not the limit.
        let thinkingOnly = SetupPlan.make(valid: [.sarvam], current: .sarvam)
        XCTAssertFalse(AppController.keysNote(for: thinkingOnly, language: "fr").contains("does not hear"))
    }

    // MARK: what was said

    func testTheLastExchangeStartsEmptyAndActionsReadAsOneLine() {
        XCTAssertEqual(IslandModel().lastYouSaid, "")
        XCTAssertEqual(IslandModel().lastSaathiSaid, "")
        XCTAssertEqual(AppController.describe(.say(SayAction(text: "hi"))), "say: hi")
        XCTAssertEqual(AppController.describe(.showStep(ShowStepAction(title: "Open Spotify", index: 1, total: 3))), "show_step 1/3: Open Spotify")
        XCTAssertEqual(AppController.describe(.openUrl(OpenUrlAction(url: "https://x.y"))), "open_url: https://x.y")
        XCTAssertEqual(AppController.describe(.lookAtScreen(LookAtScreenAction(question: "which song"))), "look_at_screen: which song")
    }

    // MARK: who speaks

    /// One question got two answers, one in the realtime voice and one in the system's: the model
    /// called `show_step`, and the performer read the narration out over the model's own audio.
    /// On a lane whose session speaks for itself, the performer says nothing — the island still
    /// shows the step, and an `open_url` is still opened.
    func testNarrationIsNotReadOutOverASessionThatSpeaksForItself() {
        let say = SaathiAction.say(SayAction(text: "hello"))
        let step = SaathiAction.showStep(ShowStepAction(title: "Open Spotify", index: 1, total: 2))
        let open = SaathiAction.openUrl(OpenUrlAction(url: "https://example.org"))
        XCTAssertFalse(VoiceConductor.performs(say, sessionSpeaksForItself: true))
        XCTAssertFalse(VoiceConductor.performs(step, sessionSpeaksForItself: true))
        XCTAssertTrue(VoiceConductor.performs(open, sessionSpeaksForItself: true))
        XCTAssertTrue(VoiceConductor.performs(say, sessionSpeaksForItself: false))
        XCTAssertTrue(VoiceConductor.performs(step, sessionSpeaksForItself: false))
    }

    // MARK: the status pill in the band

    /// The pill describes the lane in use. A red "Set up backend" over a config that talks straight
    /// to OpenAI with its own key told someone with a working install to configure something they
    /// will never use.
    func testThePillNamesTheVendorWhenYourOwnKeyIsInUse() {
        let pill = AppController.connectionPill(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o"))
        XCTAssertEqual(pill, AppController.ConnectionPill(title: "api.openai.com", isConfigured: true))
        let claude = AppController.connectionPill(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-a"))
        XCTAssertEqual(claude, AppController.ConnectionPill(title: "api.anthropic.com", isConfigured: true))
    }

    func testThePillAsksForAKeyWhenTheLaneNeedsOneAndHasNone() {
        let pill = AppController.connectionPill(for: SaathiConfiguration(provider: .openai))
        XCTAssertEqual(pill, AppController.ConnectionPill(title: "Add a key", isConfigured: false))
    }

    func testThePillNamesTheBackendOnlyOnTheHostedLane() {
        XCTAssertEqual(
            AppController.connectionPill(for: SaathiConfiguration(provider: .hosted)),
            AppController.ConnectionPill(title: "Set up backend", isConfigured: false))
        XCTAssertEqual(
            AppController.connectionPill(for: SaathiConfiguration(provider: .hosted, token: "tok")),
            AppController.ConnectionPill(title: "api.saathi.dev", isConfigured: true))
        XCTAssertEqual(
            AppController.connectionPill(for: SaathiConfiguration(provider: .hosted, backendUrl: "https://saathi.example.org/", token: "tok")),
            AppController.ConnectionPill(title: "saathi.example.org", isConfigured: true))
    }

    /// A local server is told apart by its port; a vendor never is.
    func testThePillKeepsThePortOfALocalServer() {
        XCTAssertEqual(
            AppController.connectionPill(for: SaathiConfiguration(provider: .local)),
            AppController.ConnectionPill(title: "localhost:11434", isConfigured: true))
    }

    /// The Setup tab's Backend rows only mean anything on the hosted lane; elsewhere they say so
    /// instead of reporting a token "missing" that nothing would read.
    func testTheBackendRowsSayNotUsedOffTheHostedLane() {
        XCTAssertEqual(AppController.backendTitle(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")), "not used")
        XCTAssertEqual(AppController.backendTitle(for: SaathiConfiguration(provider: .hosted)), "Set up backend")
        XCTAssertEqual(AppController.backendTitle(for: SaathiConfiguration(provider: .hosted, token: "tok")), "api.saathi.dev")
    }

    // MARK: the key rows

    /// One field per key, always on show; a saved key is its placeholder, so replacing it is a
    /// paste and one Save.
    func testASavedKeyIsTheFieldsPlaceholder() {
        XCTAssertEqual(IslandSetupView.placeholder(for: .saved(masked: "sk-…u6MA")), "sk-…u6MA — paste to replace")
        XCTAssertEqual(IslandSetupView.placeholder(for: .empty), "paste a key")
    }

    func testTheProviderTitleReadsAsAProviderAndAModel() {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        XCTAssertEqual(AppController.providerTitle(for: configuration), "openai · gpt-4o-mini")
    }

    /// The three privacy lines are the most consequential sentences in the app; they must stay
    /// pinned to the lane and not drift into marketing.
    func testThePrivacyLineFollowsTheLane() {
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
            "your voice leaves as audio")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-a")),
            "only the transcript is sent")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .local)),
            "stays on this machine")
    }

    /// With Sarvam's ears the audio goes whoever does the thinking. Home and the Voice rows say so.
    func testThePrivacyLineSaysWhenSarvamHearsTheVoice() {
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)),
            "your voice leaves as audio, to Sarvam")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k")),
            "only the transcript is sent", "asked for, not assumed")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(sarvamKey: "k", speech: .sarvam)),
            "your voice leaves as audio, to Sarvam", "a model on this Mac, with Sarvam's ears in front of it")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o", speech: .sarvam)),
            "your voice leaves as audio", "the realtime lane does not read `speech`")
    }

    func testTheVoiceRowSaysWhoseVoiceItIs() {
        XCTAssertEqual(
            AppController.voiceTitle(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
            SaathiProvider.of(.openai).defaultVoice)
        XCTAssertEqual(
            AppController.voiceTitle(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o", voice: "marin")),
            "marin")
        XCTAssertEqual(
            AppController.voiceTitle(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)),
            "Sarvam · shubh")
        XCTAssertEqual(
            AppController.voiceTitle(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", voice: "Ishita", speech: .sarvam)),
            "Sarvam · ishita")
        XCTAssertEqual(
            AppController.voiceTitle(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-a")),
            "this Mac's")
    }

    /// First run opens on Setup, and only first run. "First run" is "no provider has a credential",
    /// which is a fact about the config rather than a flag that can get out of step with it.
    func testTheIslandOpensOnSetupOnlyWhileNothingIsConfigured() {
        XCTAssertEqual(AppController.openingTab(for: SaathiConfiguration()), .setup)
        XCTAssertEqual(
            AppController.openingTab(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
            .home)
        XCTAssertEqual(
            AppController.openingTab(for: SaathiConfiguration(provider: .hosted, token: "tok")),
            .home)
        // A local setup with Ollama actually running is a legitimate configuration, but nothing on
        // disk can tell us that, so an empty config still opens on Setup.
        XCTAssertEqual(AppController.openingTab(for: SaathiConfiguration(provider: .local)), .setup)
    }

    /// Regression for the bug where reopening Setup with an empty field but a remembered `.saved`
    /// verdict erased a working key: the Setup fields live in view-local state that does not
    /// survive the view leaving the tree, so an empty field must fall back to what is already on
    /// disk rather than reading as "no key".
    func testAnEmptyFieldFallsBackToTheStoredKey() {
        XCTAssertEqual(AppController.effectiveKey(field: "", stored: "sk-existing"), "sk-existing")
        XCTAssertEqual(AppController.effectiveKey(field: "   ", stored: "sk-existing"), "sk-existing")
    }

    /// Regression: a new key typed over a saved one and never Checked left Save disabled, the old
    /// rejected key on disk, and the voice failing with "not connected". Save now checks it itself.
    func testATypedKeyWithoutAnAcceptedVerdictNeedsACheckBeforeSave() {
        XCTAssertEqual(AppController.keysNeedingCheck(
            fields: VendorKeys(openAI: "sk-new"), states: KeyStates(openAI: .editing)), [.openai])
        XCTAssertEqual(AppController.keysNeedingCheck(
            fields: VendorKeys(openAI: "sk-new"), states: KeyStates(openAI: .saved(masked: "…old1"))), [.openai],
            "a reopened row still carries the old key's verdict; it says nothing about the new text")
        XCTAssertEqual(AppController.keysNeedingCheck(
            fields: VendorKeys(openAI: "sk-new", sarvam: "sk-s", anthropic: "sk-ant"),
            states: KeyStates(openAI: .checked(.rejected("no")), sarvam: .empty, anthropic: .editing)),
            [.openai, .sarvam, .anthropic], "in the order Setup lists them")
    }

    /// Regression: a new key was checked ("works"), the island collapsed and took the text with it,
    /// and Save wrote the old, rejected key from disk back under the new key's green tick.
    func testAWorksVerdictIsOnlyAboutTheTextItChecked() {
        let saved = KeyFieldState.saved(masked: "…old1")
        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: false, seeded: saved), saved)
        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: false, seeded: .empty), .empty)
        XCTAssertEqual(AppController.verdict(.editing, isTyped: false, seeded: saved), saved)
        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: true, seeded: saved), .checked(.valid))

        // With no key on disk, a leftover "works" over an empty field must not promise a plan.
        let decision = AppController.setupDecision(
            fields: VendorKeys(), states: KeyStates(openAI: .checked(.valid)),
            configuration: SaathiConfiguration())
        XCTAssertEqual(decision.keys.openAI, "")
        XCTAssertNotEqual(decision.plan.provider, .openai)
    }

    /// A field with only a stray space in it is an empty field: nothing was typed, so nothing is
    /// checked and nothing counts as pasted.
    func testAFieldOfWhitespaceIsNotATypedKey() {
        XCTAssertEqual(AppController.typed(in: VendorKeys(openAI: "  ", sarvam: "sk-s", anthropic: "\n")), [.sarvam])
        XCTAssertEqual(AppController.typed(in: VendorKeys()), [])
    }

    func testAcceptedCheckingAndEmptyFieldsNeedNoCheck() {
        XCTAssertEqual(AppController.keysNeedingCheck(
            fields: VendorKeys(openAI: "sk-new", anthropic: "sk-ant"),
            states: KeyStates(openAI: .checked(.valid), anthropic: .checking)), [])
        XCTAssertEqual(AppController.keysNeedingCheck(
            fields: VendorKeys(openAI: "  "), states: KeyStates(openAI: .saved(masked: "…old1"))), [])
    }

    func testANonEmptyFieldWinsOverAnyStoredKey() {
        XCTAssertEqual(AppController.effectiveKey(field: "sk-new", stored: "sk-old"), "sk-new")
        XCTAssertEqual(AppController.effectiveKey(field: "sk-new", stored: nil), "sk-new")
    }

    /// Nothing typed and nothing stored is genuinely no key — the fallback must not invent one.
    func testNoFieldAndNoStoredKeyIsGenuinelyEmpty() {
        XCTAssertEqual(AppController.effectiveKey(field: "", stored: nil), "")
        XCTAssertEqual(AppController.effectiveKey(field: "  ", stored: ""), "")
    }
}

// MARK: - Where it could think

@MainActor
final class ProviderChoiceTests: XCTestCase {

    func testThePickerOffersEachVendorWithAKeyAndThisMac() {
        let all = SaathiConfiguration(provider: .sarvam, openaiKey: "o", anthropicKey: "a", sarvamKey: "s")
        let choices = AppController.providerChoices(for: all)
        XCTAssertEqual(choices.map(\.kind), [.openai, .sarvam, .anthropic, .local])
        XCTAssertEqual(choices.map(\.title), ["OpenAI", "Sarvam", "Anthropic", "This Mac"])
    }

    /// One place to think is nothing to pick from, and the row stays a line of text.
    func testWithNoKeysThereIsOnlyThisMac() {
        XCTAssertEqual(AppController.providerChoices(for: SaathiConfiguration()).map(\.kind), [.local])
    }

    func testTheHostedServiceIsOfferedOnlyWithATokenForIt() {
        let trial = SaathiConfiguration(provider: .hosted, openaiKey: "o", token: "tok")
        XCTAssertEqual(AppController.providerChoices(for: trial).map(\.kind), [.openai, .local, .hosted])
        XCTAssertEqual(
            AppController.providerChoices(for: SaathiConfiguration(openaiKey: "o")).map(\.kind), [.openai, .local])
    }

    /// Whatever is in use is always on the list, or the picker would show nothing selected.
    func testWhatIsInUseIsAlwaysOffered() {
        XCTAssertEqual(
            AppController.providerChoices(for: SaathiConfiguration(provider: .openai)).map(\.kind), [.local, .openai])
        XCTAssertEqual(
            AppController.providerChoices(for: SaathiConfiguration(provider: .hosted)).map(\.kind), [.local, .hosted])
    }

    /// A legacy shared key belongs to the provider the file names, here as everywhere in Setup.
    func testALegacyKeyCountsForTheProviderItWasWrittenFor() {
        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
        XCTAssertEqual(AppController.storedVendors(in: legacy), [.sarvam])
        XCTAssertEqual(AppController.providerChoices(for: legacy).map(\.kind), [.sarvam, .local])
    }

    func testTheProviderInUseIsTheOneTheFileNames() {
        XCTAssertNil(AppController.providerInUse(SaathiConfiguration()), "none named is none chosen")
        XCTAssertEqual(AppController.providerInUse(SaathiConfiguration(provider: .local)), .local)
        XCTAssertEqual(AppController.providerInUse(SaathiConfiguration(provider: .hosted, token: "tok")), .hosted)
        XCTAssertNil(
            AppController.providerInUse(SaathiConfiguration(provider: .hosted, token: "  ")),
            "the hosted service with no token is not somewhere to stay")
    }

    /// Picking This Mac files the shared key under the vendor it was used for, so it is still
    /// there — and still Sarvam's — when Sarvam is picked again.
    func testPickingAnotherProviderKeepsALegacyKeyWithItsVendor() {
        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
        let plan = SetupPlan.choosing(.local, valid: AppController.storedVendors(in: legacy))
        var keys = VendorKeys()
        for vendor in plan.stored { keys[vendor] = legacy.credential(for: vendor) ?? "" }
        let local = plan.applied(to: legacy, keys: keys)
        XCTAssertEqual(local.provider, .local)
        XCTAssertEqual(local.sarvamKey, "sk-legacy")
        XCTAssertEqual(AppController.storedVendors(in: local), [.sarvam])
        XCTAssertEqual(AppController.providerChoices(for: local).map(\.kind), [.sarvam, .local])
    }

    func testTheSarvamSwitchIsOnlyThereWhenItCouldBeSwitched() {
        XCTAssertTrue(AppController.sarvamSpeechAvailable(
            for: SaathiConfiguration(provider: .anthropic, anthropicKey: "a", sarvamKey: "s")))
        XCTAssertTrue(
            AppController.sarvamSpeechAvailable(for: SaathiConfiguration(sarvamKey: "s")),
            "a model on this Mac can have Sarvam's ears")
        XCTAssertFalse(
            AppController.sarvamSpeechAvailable(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "a")),
            "no Sarvam key")
        XCTAssertFalse(
            AppController.sarvamSpeechAvailable(
                for: SaathiConfiguration(provider: .openai, openaiKey: "o", sarvamKey: "s")),
            "the realtime lane carries its own speech")
    }
}

// MARK: - Relaunching ourselves

@MainActor
final class RestartTests: XCTestCase {

    func testTheIslandDoesNotAskForARestartUntilSomethingNeedsOne() {
        XCTAssertFalse(IslandModel().needsRestart)
    }

    /// The bug this exists for: macOS asks an app requesting Input Monitoring to quit and reopen,
    /// then relaunches it through LaunchServices by code signature. An ad-hoc signed app has no
    /// stable identity to bring back, so it is quit and never reopened.
    func testTerminateHappensOnlyAfterTheNewInstanceIsConfirmedLaunched() async {
        var terminated = false
        let launched = await AppRelauncher.relaunch(
            bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            launch: { _ in true },
            terminate: { terminated = true })

        XCTAssertTrue(launched)
        XCTAssertTrue(terminated)
    }

    /// A terminate that races the spawn is a quit with no reopen — which is the exact failure this
    /// code exists to replace, so it must not be reintroduced here.
    func testAFailedLaunchDoesNotTerminate() async {
        var terminated = false
        let launched = await AppRelauncher.relaunch(
            bundleURL: URL(fileURLWithPath: "/nonexistent/Nothing.app"),
            launch: { _ in false },
            terminate: { terminated = true })

        XCTAssertFalse(launched)
        XCTAssertFalse(terminated, "quitting after a failed relaunch leaves the person with nothing")
    }
}
