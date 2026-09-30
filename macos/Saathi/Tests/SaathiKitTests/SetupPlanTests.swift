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

    /// The plan for whichever keys work, with nothing pasted just now and nothing in use — the
    /// question a fresh install asks.
    private func fresh(openAI: Bool = false, sarvam: Bool = false, anthropic: Bool = false) -> SetupPlan {
        var valid: Set<ProviderKind> = []
        if openAI { valid.insert(.openai) }
        if sarvam { valid.insert(.sarvam) }
        if anthropic { valid.insert(.anthropic) }
        return SetupPlan.make(valid: valid)
    }

    // MARK: which provider

    func testAnOpenAIKeyBuysTheRealtimeLane() {
        let plan = fresh(openAI: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.lane, .realtime)
        XCTAssertEqual(plan.voiceModel, "gpt-realtime")
        XCTAssertEqual(plan.model, "gpt-4o-mini")
        XCTAssertEqual(plan.speech, .device, "the realtime lane carries its own speech")
        XCTAssertTrue(plan.storedButUnused.isEmpty)
    }

    func testAnthropicAloneGetsTheChainLaneOnThisMac() {
        let plan = fresh(anthropic: true)
        XCTAssertEqual(plan.provider, .anthropic)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "claude-sonnet-5")
        XCTAssertTrue(plan.voiceModel.isEmpty, "the chain lane opens no socket")
        XCTAssertEqual(plan.speech, .device)
        XCTAssertTrue(plan.storedButUnused.isEmpty, "the key it has is the key it uses")
    }

    /// A Sarvam key buys Sarvam whole: its ears and its mouth as well as its thinking, because
    /// without them it cannot be spoken to in the languages it is chosen for.
    func testASarvamKeyBuysSarvamHeardAndSpoken() {
        let plan = fresh(sarvam: true)
        XCTAssertEqual(plan.provider, .sarvam)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "sarvam-105b")
        XCTAssertTrue(plan.voiceModel.isEmpty)
        XCTAssertEqual(plan.speech, .sarvam)
    }

    func testNoKeysFallsBackToWhateverIsOnThisMachine() {
        let plan = fresh()
        XCTAssertEqual(plan.provider, .local)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.speech, .device)
        XCTAssertTrue(plan.stored.isEmpty)
    }

    /// With nothing pasted and nothing in use: OpenAI for its socket, then Sarvam, then Claude.
    func testWithNothingToGoOnTheMostCapableKeyWins() {
        XCTAssertEqual(fresh(openAI: true, sarvam: true, anthropic: true).provider, .openai)
        XCTAssertEqual(fresh(sarvam: true, anthropic: true).provider, .sarvam)
    }

    /// A key that has just been pasted is a statement of what its owner wants. Otherwise the key
    /// they just added would do nothing they could see.
    func testAKeyJustPastedMovesSaathiToIt() {
        let both: Set<ProviderKind> = [.openai, .sarvam]
        XCTAssertEqual(SetupPlan.make(valid: both, typed: [.sarvam], current: .openai).provider, .sarvam)
        XCTAssertEqual(SetupPlan.make(valid: both, typed: [.openai], current: .sarvam).provider, .openai)
        XCTAssertEqual(
            SetupPlan.make(valid: both, typed: [.openai, .sarvam], current: .sarvam).provider, .openai,
            "both at once is OpenAI, for the reason it always was: the realtime socket")
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai, .anthropic], typed: [.openai], current: .anthropic).provider, .openai,
            "OpenAI arriving still takes over from Claude")
    }

    /// An Anthropic key is there to look at the screen. Pasting one never moves anyone off the
    /// provider they are using.
    func testAnAnthropicKeyOnItsOwnNeverTakesTheConversation() {
        for current in [ProviderKind.openai, .sarvam] {
            let plan = SetupPlan.make(valid: [current, .anthropic], typed: [.anthropic], current: current)
            XCTAssertEqual(plan.provider, current)
        }
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: .local).provider, .local)
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: .hosted).provider, .hosted)
        XCTAssertEqual(
            SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: nil).provider, .anthropic,
            "with nothing chosen, the one key there is does the thinking")
    }

    /// With nothing new pasted, what is in use stays in use — so choosing Sarvam in the picker is
    /// not undone by the next Save.
    func testWhatIsInUseStaysInUseWhileItsKeyWorks() {
        let all: Set<ProviderKind> = [.openai, .sarvam, .anthropic]
        for current in [ProviderKind.openai, .sarvam, .anthropic, .local, .hosted] {
            XCTAssertEqual(SetupPlan.make(valid: all, current: current).provider, current)
        }
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai], current: .sarvam).provider, .openai,
            "a provider whose key is gone is not stayed on")
        XCTAssertEqual(SetupPlan.make(valid: [], current: .sarvam).provider, .local)
    }

    func testAKeyThatWasTypedButRefusedDecidesNothing() {
        XCTAssertEqual(SetupPlan.make(valid: [.openai], typed: [.sarvam], current: .openai).provider, .openai)
    }

    func testChoosingByHandIsTakenAtItsWord() {
        let valid: Set<ProviderKind> = [.openai, .sarvam, .anthropic]
        XCTAssertEqual(SetupPlan.choosing(.sarvam, valid: valid).provider, .sarvam)
        XCTAssertEqual(SetupPlan.choosing(.sarvam, valid: valid).speech, .sarvam)
        XCTAssertEqual(SetupPlan.choosing(.anthropic, valid: valid).speech, .device)
        let local = SetupPlan.choosing(.local, valid: valid)
        XCTAssertEqual(local.provider, .local)
        XCTAssertEqual(local.model, "llama3.2")
        XCTAssertEqual(local.stored, [.openai, .sarvam, .anthropic], "the keys are kept for when they are wanted again")
    }

    // MARK: whose ears and mouth

    /// `provider: sarvam` has always listened on this Mac and sent only the words. A Save that
    /// has nothing to do with Sarvam must not turn that into sending audio.
    func testSarvamsSpeechIsAskedForNotAssumed() {
        let thinkingOnly = SetupPlan.make(valid: [.sarvam], current: .sarvam)
        XCTAssertEqual(thinkingOnly.provider, .sarvam)
        XCTAssertEqual(thinkingOnly.speech, .device)
        XCTAssertTrue(thinkingOnly.explanation.contains("Your voice stays here"), thinkingOnly.explanation)

        let unrelated = SetupPlan.make(valid: [.sarvam, .anthropic], typed: [.anthropic], current: .sarvam)
        XCTAssertEqual(unrelated.speech, .device, "an Anthropic key being pasted asks Sarvam for nothing")

        XCTAssertEqual(
            SetupPlan.make(valid: [.sarvam], typed: [.sarvam], current: .sarvam).speech, .sarvam,
            "pasting the Sarvam key is asking for it")
        XCTAssertEqual(
            SetupPlan.make(valid: [.sarvam], current: .sarvam, speech: .sarvam).speech, .sarvam,
            "and once asked for it stays")
    }

    /// Claude, or a model on this Mac, with Sarvam's ears in front of it: a configuration written
    /// by hand or made with the switch in Setup, and one a Save must describe rather than undo.
    func testSarvamsSpeechCanSitInFrontOfAnotherThinker() {
        let claude = SetupPlan.make(valid: [.sarvam, .anthropic], current: .anthropic, speech: .sarvam)
        XCTAssertEqual(claude.provider, .anthropic)
        XCTAssertEqual(claude.speech, .sarvam)
        XCTAssertTrue(claude.explanation.contains("think with Claude"), claude.explanation)
        XCTAssertTrue(claude.explanation.contains("straight to Sarvam"), claude.explanation)
        XCTAssertTrue(
            claude.explanation.contains("and so does what I say back"),
            "Claude's replies go to Sarvam to be spoken, which they otherwise never would: \(claude.explanation)")
        XCTAssertTrue(claude.storedButUnused.isEmpty, "the Sarvam key is in use: it hears and speaks")

        let local = SetupPlan.make(valid: [.sarvam], current: .local, speech: .sarvam)
        XCTAssertEqual(local.provider, .local)
        XCTAssertEqual(local.speech, .sarvam)
        XCTAssertTrue(local.explanation.contains("straight to Sarvam"), local.explanation)
        XCTAssertTrue(local.explanation.contains("and so does what I say back"), local.explanation)
        XCTAssertFalse(local.explanation.contains("Nothing you say leaves it"), local.explanation)

        // With Sarvam doing the thinking its replies were Sarvam's to begin with.
        XCTAssertFalse(fresh(sarvam: true).explanation.contains("what I say back"))
    }

    func testSarvamsSpeechNeedsASarvamKeyAndTheChainLane() {
        let noKey = SetupPlan.make(valid: [.anthropic], current: .anthropic, speech: .sarvam)
        XCTAssertEqual(noKey.speech, .device, "asked for with no key to do it with")
        XCTAssertTrue(noKey.explanation.contains("Your voice stays here"), noKey.explanation)

        let realtime = SetupPlan.make(valid: [.openai, .sarvam], current: .openai, speech: .sarvam)
        XCTAssertEqual(realtime.speech, .device, "the realtime lane carries its own speech")
    }

    /// Someone who picks This Mac is picking somewhere their voice stays.
    func testLeavingSarvamPutsSpeechBackOnThisMac() {
        XCTAssertEqual(SetupPlan.choosing(.local, valid: [.sarvam]).speech, .device)
        XCTAssertEqual(SetupPlan.choosing(.anthropic, valid: [.sarvam, .anthropic]).speech, .device)
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai, .sarvam], typed: [.openai], current: .sarvam, speech: .sarvam).speech,
            .device)
        XCTAssertEqual(
            SetupPlan.make(valid: [.anthropic], current: .sarvam, speech: .sarvam).provider, .anthropic,
            "a Sarvam key that stopped working takes its speech with it")
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], current: .sarvam, speech: .sarvam).speech, .device)
    }

    // MARK: which keys do what

    /// The Anthropic key was reported as "saved, nothing uses it" long after `ScreenSight` began
    /// preferring it. It looks at the screen, and the plan says so.
    func testTheOtherKeysAreSavedAndTheOneThatLooksAtTheScreenIsNamed() {
        let plan = fresh(openAI: true, anthropic: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.stored, [.openai, .anthropic])
        XCTAssertEqual(plan.eye, .anthropic)
        XCTAssertTrue(plan.storedButUnused.isEmpty, "it is used: it looks")
    }

    func testTheEyeIsClaudeWhenItIsThereAndOpenAIOtherwise() {
        XCTAssertEqual(fresh(openAI: true).eye, .openai)
        XCTAssertEqual(fresh(openAI: true, sarvam: true, anthropic: true).eye, .anthropic)
        XCTAssertNil(fresh(sarvam: true).eye, "Sarvam does not look at screens; one of the other two has to")
        XCTAssertNil(fresh().eye)
    }

    func testAKeyThatNeitherTalksNorLooksIsNamedAsUnused() {
        let all = SetupPlan.make(valid: [.openai, .sarvam, .anthropic], current: .sarvam)
        XCTAssertEqual(all.storedButUnused, [.openai], "Sarvam talks, Claude looks, and OpenAI waits")
        XCTAssertEqual(fresh(openAI: true, sarvam: true).storedButUnused, [.sarvam])
    }

    // MARK: the sentence

    /// Every branch has to produce a sentence. An empty explanation would render as a blank line in
    /// the panel, which reads as a bug rather than as a default.
    func testEveryPlanExplainsItself() {
        for provider in ProviderKind.allCases {
            for valid in [Set<ProviderKind>(), [.openai, .sarvam, .anthropic]] {
                for speech in SpeechEngine.allCases {
                    for plan in [
                        SetupPlan.choosing(provider, valid: valid),
                        SetupPlan.make(valid: valid, current: provider, speech: speech),
                    ] {
                        XCTAssertFalse(
                            plan.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "no explanation for \(provider)")
                    }
                }
            }
        }
    }

    /// The sentence and the plan, for every plan there is: it says the voice leaves as audio
    /// exactly when it will, and names Sarvam exactly when Sarvam is where it goes.
    func testTheSentenceAndThePlanNeverDisagreeAboutTheVoice() {
        let vendors = SetupPlan.vendors
        var subsets: [Set<ProviderKind>] = [[]]
        for vendor in vendors { subsets += subsets.map { $0.union([vendor]) } }
        var plans: [SetupPlan] = []
        for valid in subsets {
            for provider in ProviderKind.allCases { plans.append(SetupPlan.choosing(provider, valid: valid)) }
            for typed in subsets {
                for current in ProviderKind.allCases.map(Optional.some) + [nil] {
                    for speech in SpeechEngine.allCases {
                        plans.append(SetupPlan.make(valid: valid, typed: typed, current: current, speech: speech))
                    }
                }
            }
        }
        XCTAssertGreaterThan(plans.count, 700)
        for plan in plans {
            let leaves = plan.lane == .realtime || plan.speech == .sarvam
            XCTAssertEqual(plan.explanation.contains("leaves this machine as audio"), leaves, plan.explanation)
            XCTAssertEqual(
                plan.explanation.contains("straight to Sarvam"), plan.speech == .sarvam, plan.explanation)
            if plan.speech == .sarvam {
                XCTAssertEqual(plan.lane, .chain)
                XCTAssertTrue(plan.stored.contains(.sarvam), "Sarvam's speech with no Sarvam key: \(plan)")
            }
        }
    }

    /// The local explanation is the one a stuck person reads most, so it has to name the thing they
    /// are missing rather than say "not configured".
    func testTheLocalExplanationNamesWhatToInstall() {
        XCTAssertTrue(fresh().explanation.contains("Ollama"))
        XCTAssertTrue(fresh().explanation.contains("No key yet"))
        let chosen = SetupPlan.choosing(.local, valid: [.openai])
        XCTAssertTrue(chosen.explanation.contains("Ollama"))
        XCTAssertFalse(chosen.explanation.contains("No key yet"), "there is a key; this Mac was chosen anyway")
    }

    /// The most consequential sentences in the app. Whenever the voice will leave as audio the
    /// sentence says so, and says to whom; whenever it will not, it does not.
    func testTheSentenceSaysWhereTheVoiceGoes() {
        let openAI = fresh(openAI: true).explanation
        XCTAssertTrue(openAI.contains("leaves this machine as audio, straight to OpenAI"), openAI)

        let sarvam = fresh(sarvam: true).explanation
        XCTAssertTrue(sarvam.contains("leaves this machine as audio, straight to Sarvam"), sarvam)
        XCTAssertTrue(sarvam.contains("language"), "and that the language is the one chosen in Setup")

        for stays in [fresh(anthropic: true), fresh(), SetupPlan.choosing(.local, valid: [.sarvam])] {
            XCTAssertFalse(stays.explanation.contains("leaves this machine"), stays.explanation)
        }
        XCTAssertTrue(fresh(anthropic: true).explanation.contains("Your voice stays here"))
    }

    // MARK: applying a plan

    func testApplyingAPlanWritesTheKeysAndTheChosenProvider() {
        let plan = fresh(openAI: true, anthropic: true)
        let config = plan.applied(to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", anthropic: "sk-a"))

        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertEqual(config.anthropicKey, "sk-a", "a key that is not doing the talking is still stored")
        XCTAssertEqual(config.model, "gpt-4o-mini")
        XCTAssertEqual(config.voiceModel, "gpt-realtime")
        XCTAssertNil(config.speech)
        XCTAssertEqual(config.credential(for: .openai), "sk-o")
    }

    func testApplyingASarvamPlanAsksForSarvamsSpeechAndOnlyThen() {
        let existing = SaathiConfiguration(provider: .openai, model: "gpt-4o-mini", openaiKey: "sk-o", voiceModel: "gpt-realtime")
        let plan = SetupPlan.make(valid: [.openai, .sarvam], typed: [.sarvam], current: .openai)
        let sarvam = plan.applied(to: existing, keys: VendorKeys(openAI: "sk-o", sarvam: "sk-s"))

        XCTAssertEqual(sarvam.provider, .sarvam)
        XCTAssertEqual(sarvam.speech, .sarvam)
        XCTAssertEqual(sarvam.sarvamKey, "sk-s")
        XCTAssertEqual(sarvam.openaiKey, "sk-o", "kept: it looks at the screen, and it is a click away in the picker")
        XCTAssertEqual(sarvam.model, "sarvam-105b")
        XCTAssertNil(sarvam.voiceModel, "no socket, no voice model")
        XCTAssertTrue(SarvamSpeech.isOn(sarvam))

        // And back again: the voice no longer goes to Sarvam once the sentence stops saying it does.
        let back = SetupPlan.choosing(.openai, valid: [.openai, .sarvam]).applied(to: sarvam, keys: VendorKeys())
        XCTAssertEqual(back.provider, .openai)
        XCTAssertNil(back.speech)
        XCTAssertEqual(back.model, "gpt-4o-mini")
        XCTAssertEqual(back.voiceModel, "gpt-realtime")
        XCTAssertEqual(back.sarvamKey, "sk-s")
        XCTAssertEqual(back.openaiKey, "sk-o", "a blank for a key that is already there keeps it")
    }

    /// `"model": "sarvam-105b-conversations"` is one line in shell.json. Replacing a key must not
    /// quietly put the default back.
    func testAModelChosenByHandSurvivesAKeyBeingReplaced() {
        let existing = SaathiConfiguration(
            provider: .sarvam, model: "sarvam-105b-conversations", sarvamKey: "sk-old", voice: "ishita", speech: .sarvam)
        let plan = SetupPlan.make(valid: [.sarvam], typed: [.sarvam], current: .sarvam)
        let config = plan.applied(to: existing, keys: VendorKeys(sarvam: "sk-new"))
        XCTAssertEqual(config.model, "sarvam-105b-conversations")
        XCTAssertEqual(config.voice, "ishita")
        XCTAssertEqual(config.sarvamKey, "sk-new")
    }

    /// A voice chosen for one provider is never sent to another that does not have it.
    func testAVoiceDoesNotFollowAChangeOfProvider() {
        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o", sarvamKey: "sk-s", voice: "marin")
        let config = SetupPlan.choosing(.sarvam, valid: [.openai, .sarvam]).applied(to: existing, keys: VendorKeys())
        XCTAssertNil(config.voice)
    }

    /// A base URL written by hand is one provider's. Carried to the next it would post a Sarvam
    /// key to somebody's Ollama box while the sentence said "through Sarvam" — so it goes when the
    /// provider does, and stays when only a key is replaced.
    func testABaseURLDoesNotFollowAChangeOfProvider() {
        let ollama = SaathiConfiguration(providerBaseUrl: "http://192.168.1.9:11434")
        let sarvam = SetupPlan.make(valid: [.sarvam], typed: [.sarvam])
            .applied(to: ollama, keys: VendorKeys(sarvam: "sk-s"))
        XCTAssertNil(sarvam.providerBaseUrl)
        XCTAssertEqual(sarvam.resolvedProviderBaseURL, "https://api.sarvam.ai/v1")

        let proxied = SaathiConfiguration(
            provider: .openai, providerBaseUrl: "https://proxy.example/v1", openaiKey: "sk-old")
        let sameProvider = SetupPlan.make(valid: [.openai], typed: [.openai], current: .openai)
            .applied(to: proxied, keys: VendorKeys(openAI: "sk-new"))
        XCTAssertEqual(sameProvider.providerBaseUrl, "https://proxy.example/v1")

        let thisMac = SetupPlan.choosing(.local, valid: [.openai]).applied(to: proxied, keys: VendorKeys())
        XCTAssertNil(thisMac.providerBaseUrl, "\"Nothing you say leaves it\" is not said over a proxy's address")
    }

    /// Settings a person chose by hand are not ours to throw away because they pasted a key.
    func testApplyingAPlanKeepsUnrelatedSettings() {
        let existing = SaathiConfiguration(language: "ml", backendUrl: "https://example.test", token: "tok", name: "Asha")
        let config = fresh(openAI: true).applied(to: existing, keys: VendorKeys(openAI: "sk-o"))

        XCTAssertEqual(config.backendUrl, "https://example.test")
        XCTAssertEqual(config.token, "tok")
        XCTAssertEqual(config.language, "ml")
        XCTAssertEqual(config.name, "Asha")
    }

    /// A key that did not validate is not saved. Storing a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working.
    func testAKeyThatDidNotValidateIsNotStored() {
        let config = fresh(openAI: true).applied(
            to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", sarvam: "sk-bad", anthropic: "sk-bad"))
        XCTAssertNil(config.anthropicKey)
        XCTAssertNil(config.sarvamKey)
    }

    /// Keys pasted from many sources arrive with trailing whitespace or newlines. Trimming is
    /// non-negotiable; if skipped, the key is refused as malformed on the next launch, which looks
    /// like the key suddenly stopped working.
    func testAKeyWithLeadingTrailingWhitespaceIsTrimmedBeforeStorage() {
        let config = fresh(openAI: true, sarvam: true, anthropic: true).applied(
            to: SaathiConfiguration(),
            keys: VendorKeys(openAI: "  sk-o  \n", sarvam: "\tsk-s ", anthropic: "  sk-a  \n"))

        XCTAssertEqual(config.openaiKey, "sk-o", "leading and trailing whitespace must be trimmed")
        XCTAssertEqual(config.sarvamKey, "sk-s")
        XCTAssertEqual(config.anthropicKey, "sk-a", "a key that is not doing the talking is trimmed too")
    }

    /// A key that is only whitespace is not stored as an empty string — it is not stored at all.
    /// Empty strings would be indistinguishable from "not present" and would clutter config.
    func testAWhitespaceOnlyKeyIsStoredAsNilNotEmptyString() {
        let config = fresh(openAI: true, anthropic: true).applied(
            to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", anthropic: "   \n\t   "))

        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertNil(config.anthropicKey, "whitespace-only key becomes nil, not empty string")
    }

    /// When a key did not validate, an existing stored key for that provider is kept — it was
    /// good once. Clearing it would erase a working credential just because this attempt failed,
    /// which is worse than keeping a stale one that the user can see and update.
    func testAnExistingKeyIsPreservedWhenNewAttemptDidNotValidate() {
        let existing = SaathiConfiguration(anthropicKey: "sk-a-old")
        let config = fresh().applied(to: existing, keys: VendorKeys(anthropic: "sk-a-bad"))

        XCTAssertEqual(config.anthropicKey, "sk-a-old", "existing valid key preserved when new attempt fails")
    }

    func testKeysAreReadAndWrittenByVendorAndNothingElseHasOne() {
        var keys = VendorKeys(openAI: "o", sarvam: "s", anthropic: "a")
        XCTAssertEqual(SetupPlan.vendors.map { keys[$0] }, ["o", "s", "a"])
        keys[.sarvam] = "new"
        keys[.local] = "ignored"
        XCTAssertEqual(keys, VendorKeys(openAI: "o", sarvam: "new", anthropic: "a"))
        XCTAssertEqual(keys[.hosted], "")
    }
}
