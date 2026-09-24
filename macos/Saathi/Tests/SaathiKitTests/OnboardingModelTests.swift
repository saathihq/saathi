//
//  OnboardingModelTests.swift
//  SaathiKitTests
//
//  First run, driven by events with no window behind it: the order, what unlocks Continue, the
//  two branches the spec says must never block (a denied permission, a refused trial), and what
//  ends up in shell.json.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingModelTests: XCTestCase {

    private let palette = ["green", "blue", "red", "teal"]
    private let languages = ["en-IN", "hi-IN", "ta-IN"]

    private func model() -> OnboardingModel {
        OnboardingModel(supportedLanguages: languages, palette: palette)
    }

    /// Sends events and returns the steps visited, without consecutive repeats.
    private func walk(_ model: inout OnboardingModel, _ events: [OnboardingEvent]) -> [OnboardingStep] {
        var steps = [model.step]
        for event in events {
            model.handle(event)
            if model.step != steps.last { steps.append(model.step) }
        }
        return steps
    }

    private let throughPermissions: [OnboardingEvent] = [
        .next, .choseColour("teal"), .next, .next,
        .permissionResolved(.microphone, .granted),
        .permissionResolved(.speechRecognition, .granted),
        .permissionResolved(.inputMonitoring, .granted),
    ]

    private var throughQuestions: [OnboardingEvent] {
        throughPermissions + [
            .next,                                   // all set → mic check
            .heard("hello"), .next,                  // → hold to talk
            .keysHeld, .next,                        // → questions
            .answered("my name is asha"), .answered("I want to learn the tabla"),
            .answered("calm and slow"), .answered("Tamil"),
        ]
    }

    func testTheWholeHappyPathInOrder() {
        var m = model()
        let steps = walk(&m, throughQuestions + [.trialRequested, .trialIssued, .next, .choseProvider(.hosted)])
        XCTAssertEqual(steps, [
            .welcome, .colour, .intoNotch,
            .permission(.microphone), .permission(.speechRecognition), .permission(.inputMonitoring),
            .allSet,
            .demo(.micCheck), .demo(.holdToTalk),
            .demo(.question(.name)), .demo(.question(.firstGoal)), .demo(.question(.manner)), .demo(.question(.language)),
            .demo(.trialChat), .demo(.providerChoice),
            .finished,
        ])
    }

    func testTheThreePermissionsAreTheRequiredThreeInTheSpecsOrder() {
        XCTAssertEqual(OnboardingModel.permissionOrder, [.microphone, .speechRecognition, .inputMonitoring])
        XCTAssertEqual(Set(OnboardingModel.permissionOrder), Set(Permission.allCases.filter(\.isRequired)))
    }

    // MARK: colour

    func testAColourOutsideThePaletteIsIgnoredAndNoChoiceMeansBlue() {
        var m = model()
        m.handle(.next)
        XCTAssertFalse(m.handle(.choseColour("mauve")))
        XCTAssertNil(m.colour)
        m.handle(.next)
        XCTAssertEqual(m.step, .intoNotch)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertEqual(configuration.colour, "blue")
    }

    func testChoosingAColourDoesNotLeaveTheCard() {
        var m = model()
        m.handle(.next)
        XCTAssertTrue(m.handle(.choseColour("teal")))
        XCTAssertTrue(m.handle(.choseColour("red")), "they are trying colours on; the mascot follows")
        XCTAssertEqual(m.step, .colour)
        XCTAssertEqual(m.colour, "red")
    }

    // MARK: permissions

    /// "A denied permission shows why it matters and how to grant it later; onboarding continues."
    func testADeniedPermissionIsRecordedAndDoesNotBlock() {
        var m = model()
        let steps = walk(&m, [
            .next, .next, .next,
            .permissionResolved(.microphone, .denied),
            .permissionResolved(.speechRecognition, .granted),
            .permissionResolved(.inputMonitoring, .notDetermined),
        ])
        XCTAssertEqual(steps.last, .allSet)
        XCTAssertEqual(m.deniedPermissions, [.microphone, .inputMonitoring])
    }

    func testNextDoesNothingOnAPermissionStepUntilMacOSHasAnswered() {
        var m = model()
        _ = walk(&m, [.next, .next, .next])
        XCTAssertEqual(m.step, .permission(.microphone))
        XCTAssertFalse(m.canContinue)
        XCTAssertFalse(m.handle(.next))
        XCTAssertEqual(m.step, .permission(.microphone))
    }

    /// The Input Monitoring grant lands seconds later, from System Settings, possibly while a
    /// different step is showing. It is recorded; it does not move anything.
    func testAVerdictForAPermissionThatIsNotTheCurrentStepIsRecordedOnly() {
        var m = model()
        _ = walk(&m, [.next, .next, .next, .permissionResolved(.microphone, .denied)])
        XCTAssertEqual(m.step, .permission(.speechRecognition))
        m.handle(.permissionResolved(.microphone, .granted))
        XCTAssertEqual(m.step, .permission(.speechRecognition))
        XCTAssertEqual(m.deniedPermissions, [])
    }

    // MARK: demo gates

    func testTheMicCheckContinuesOnlyOnceSomethingWasHeard() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next])
        XCTAssertEqual(m.step, .demo(.micCheck))
        XCTAssertFalse(m.canContinue)
        XCTAssertFalse(m.handle(.next))
        m.handle(.heard("   "))
        XCTAssertFalse(m.canContinue, "silence transcribed as whitespace is not hearing someone")
        m.handle(.heard("hello saathi"))
        XCTAssertTrue(m.canContinue)
        XCTAssertEqual(m.lastHeard, "hello saathi")
        m.handle(.next)
        XCTAssertEqual(m.step, .demo(.holdToTalk))
    }

    /// Without the microphone or the recogniser nothing can ever be heard, and the only other way
    /// on would be Skip demo — which skips the questions and the provider choice with it.
    func testTheMicCheckIsPassableWhenNothingCanBeHeard() {
        var noMic = model()
        _ = walk(&noMic, [.next, .next, .next,
            .permissionResolved(.microphone, .denied), .permissionResolved(.speechRecognition, .granted),
            .permissionResolved(.inputMonitoring, .granted), .next])
        XCTAssertEqual(noMic.step, .demo(.micCheck))
        XCTAssertTrue(noMic.canContinue)

        var quiet = model()
        _ = walk(&quiet, throughPermissions + [.next])
        XCTAssertFalse(quiet.canContinue)
        quiet.handle(.couldNotHear)
        XCTAssertTrue(quiet.canContinue, "a room too quiet to transcribe is not a locked door")
        XCTAssertFalse(quiet.heardSomething)
    }

    func testHoldToTalkContinuesOnlyOnceTheKeysWereHeld() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next])
        XCTAssertFalse(m.canContinue)
        m.handle(.heard("hi"))
        XCTAssertFalse(m.canContinue, "talking without the keys is not what this step teaches")
        m.handle(.keysHeld)
        XCTAssertTrue(m.canContinue)
    }

    /// Someone whose Input Monitoring was denied can never hold the keys. The step must not trap them.
    func testHoldToTalkIsPassableWhenInputMonitoringWasNotGranted() {
        var m = model()
        _ = walk(&m, [
            .next, .next, .next,
            .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
            .permissionResolved(.inputMonitoring, .notDetermined),
            .next, .heard("hi"), .next,
        ])
        XCTAssertEqual(m.step, .demo(.holdToTalk))
        XCTAssertTrue(m.canContinue)
    }

    func testSkipDemoFinishesFromAnyDemoStepAndFromNowhereElse() {
        var early = model()
        XCTAssertFalse(early.handle(.skipDemo), "there is no Skip demo on the welcome card")

        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha")])
        XCTAssertTrue(m.handle(.skipDemo))
        XCTAssertEqual(m.step, .finished)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertEqual(configuration.name, "Asha", "what was already answered is kept")
        XCTAssertEqual(configuration.onboarded, true)
        XCTAssertNil(configuration.provider, "skipping never chooses where Saathi thinks")
        XCTAssertTrue(m.opensSetupAfterwards)
    }

    // MARK: questions

    func testAnAnswerItCannotReadIsAskedOnceMoreThenDefaulted() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla")])
        XCTAssertEqual(m.step, .demo(.question(.manner)))

        m.handle(.answered("whatever you think"))
        XCTAssertEqual(m.step, .demo(.question(.manner)))
        XCTAssertTrue(m.isReasking)

        m.handle(.answered("I really don't mind"))
        XCTAssertEqual(m.step, .demo(.question(.language)))
        XCTAssertFalse(m.isReasking, "the next question starts fresh")
        XCTAssertEqual(m.answers.manner, .warmAndNormal, "the default is the middle one")

        m.handle(.answered("Klingon")); m.handle(.answered("Klingon"))
        XCTAssertEqual(m.step, .demo(.trialChat))
        XCTAssertEqual(m.answers.language, "en-IN", "the default is the first supported tag — the app lists the machine's own first")
    }

    func testAnEmptyNameIsAskedOnceMoreThenLeftUnset() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next])
        m.handle(.answered("..."))
        XCTAssertEqual(m.step, .demo(.question(.name)))
        m.handle(.answered(""))
        XCTAssertEqual(m.step, .demo(.question(.firstGoal)))
        XCTAssertNil(m.answers.name, "nobody is called a default")
    }

    func testAnsweredIsIgnoredOutsideAQuestion() {
        var m = model()
        XCTAssertFalse(m.handle(.answered("Asha")))
        XCTAssertNil(m.answers.name)
    }

    // MARK: trial and provider

    /// "Trial refused: step 6.4 says the exact reason in words and offers Skip; nothing else changes."
    func testARefusedTrialKeepsItsReasonOffersSkipAndNeverOffersHosted() {
        var m = model()
        _ = walk(&m, throughQuestions)
        XCTAssertEqual(m.step, .demo(.trialChat))
        m.handle(.trialRequested)
        XCTAssertEqual(m.trial, .asking)
        XCTAssertFalse(m.canContinue)

        m.handle(.trialFailed("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertEqual(m.trial, .failed("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertFalse(m.handle(.next), "there is no chat to have had")

        XCTAssertTrue(m.handle(.skipTrial))
        XCTAssertEqual(m.step, .demo(.providerChoice))
        XCTAssertEqual(m.availableProviderChoices, [.local, .ownKey])
        XCTAssertFalse(m.handle(.choseProvider(.hosted)), "never a fallback to hosted")
        XCTAssertEqual(m.step, .demo(.providerChoice))
    }

    func testATrialCanBeRetriedAfterAFailure() {
        var m = model()
        _ = walk(&m, throughQuestions + [.trialRequested, .trialFailed("could not reach the backend")])
        m.handle(.trialRequested)
        XCTAssertEqual(m.trial, .asking)
        m.handle(.trialIssued)
        XCTAssertEqual(m.trial, .ready)
        XCTAssertTrue(m.canContinue)
        XCTAssertEqual(m.availableProviderChoices, [.hosted, .local, .ownKey])
    }

    func testTrialEventsAreIgnoredOutsideTheTrialStep() {
        var m = model()
        XCTAssertFalse(m.handle(.trialIssued))
        XCTAssertEqual(m.trial, .notAsked)
    }

    // MARK: what is written

    func testApplyWritesWhatWasLearnedAndLeavesTheRestAlone() {
        var m = model()
        _ = walk(&m, throughQuestions + [.trialRequested, .trialIssued, .next, .choseProvider(.hosted)])
        var configuration = SaathiConfiguration(openaiKey: "sk-kept", token: "saathi_trial_abc", deviceId: "d")
        m.apply(to: &configuration)

        XCTAssertEqual(configuration.name, "Asha")
        XCTAssertEqual(configuration.colour, "teal")
        XCTAssertEqual(configuration.firstGoal, "the tabla")
        XCTAssertEqual(configuration.tone, .calm)
        XCTAssertEqual(configuration.pace, .slow)
        XCTAssertEqual(configuration.language, "ta-IN")
        XCTAssertEqual(configuration.provider, .hosted)
        XCTAssertEqual(configuration.onboarded, true)
        XCTAssertEqual(configuration.openaiKey, "sk-kept")
        XCTAssertEqual(configuration.token, "saathi_trial_abc", "the token is TrialEnrollment's to write, not this model's")
        XCTAssertFalse(m.opensSetupAfterwards)
    }

    func testLocalIsWrittenAndOwnKeyLeavesTheProviderForSetup() {
        var local = model()
        _ = walk(&local, throughQuestions + [.skipTrial, .choseProvider(.local)])
        var a = SaathiConfiguration(provider: .openai)
        local.apply(to: &a)
        XCTAssertEqual(a.provider, .local)
        XCTAssertFalse(local.opensSetupAfterwards)

        var own = model()
        _ = walk(&own, throughQuestions + [.skipTrial, .choseProvider(.ownKey)])
        var b = SaathiConfiguration()
        own.apply(to: &b)
        XCTAssertNil(b.provider, "Setup decides the provider from the keys that validate, as it does today")
        XCTAssertTrue(own.opensSetupAfterwards)
        XCTAssertEqual(own.step, .finished)
    }

    /// Quitting halfway must not mark first run done, or it never comes back.
    func testApplyBeforeTheEndDoesNotClaimToBeOnboarded() {
        var m = model()
        _ = walk(&m, throughPermissions)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertNil(configuration.onboarded)
        XCTAssertEqual(configuration.colour, "teal", "what was chosen is still kept")
    }

    func testRunningItAgainStartsFromTheTopWithNothingRemembered() {
        var m = model()
        _ = walk(&m, throughQuestions)
        m = model()
        XCTAssertEqual(m.step, .welcome)
        XCTAssertEqual(m.answers, OnboardingAnswers())
    }
}
