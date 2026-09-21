//
//  OnboardingCoordinatorTests.swift
//  SaathiShellTests
//
//  First run with the world replaced by closures: what is said and in what order, what macOS is
//  asked, what the backend is asked, and when `shell.json` is written.
//

import XCTest
import SaathiContract
import SaathiKit
@testable import SaathiShell

@MainActor
final class OnboardingCoordinatorTests: XCTestCase {

    private var spoken: [String] = []
    private var saves = 0
    private var finishes: [OnboardingModel] = []
    private var trialChat: [Bool] = []
    private var openedSettings: [Permission] = []
    private var permissionAnswers: [Permission: PermissionStatus] = [:]
    private var liveStatus: [Permission: PermissionStatus] = [:]
    private var trialError: Error?
    private var trialDelay: UInt64 = 0
    private var permissionDelay: UInt64 = 0
    private var listening: [Bool] = []

    private func coordinator() -> OnboardingCoordinator {
        var effects = OnboardingEffects()
        effects.speak = { [weak self] text, _ in self?.spoken.append(text) }
        effects.requestPermission = { [weak self] permission in
            if let delay = self?.permissionDelay, delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return self?.permissionAnswers[permission] ?? .granted
        }
        effects.setListening = { [weak self] in self?.listening.append($0) }
        effects.permissionStatus = { [weak self] in self?.liveStatus[$0] ?? .notDetermined }
        effects.openSettings = { [weak self] in self?.openedSettings.append($0) }
        effects.enrollTrial = { [weak self] in
            if let delay = self?.trialDelay, delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let error = self?.trialError { throw error }
        }
        effects.save = { [weak self] _ in self?.saves += 1 }
        effects.trialChatChanged = { [weak self] in self?.trialChat.append($0) }
        effects.finish = { [weak self] in self?.finishes.append($0) }
        return OnboardingCoordinator(
            model: OnboardingModel(supportedLanguages: ["en-IN", "ta-IN"], palette: ["blue", "teal"]),
            effects: effects)
    }

    /// Lets the permission and trial tasks run, then waits for speech.
    private func settle(_ c: OnboardingCoordinator) async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await c.settle()
    }

    private func toPermissions(_ c: OnboardingCoordinator) async {
        c.begin(); c.next(); c.choose(colour: "teal"); c.next(); c.next()
        await settle(c)
    }

    private func toQuestions(_ c: OnboardingCoordinator) async {
        await toPermissions(c)
        for _ in 0..<3 { c.requestCurrentPermission(); await settle(c) }
        c.next()
        c.heard("hello"); c.next()
        c.keysHeld(); c.next()
        await settle(c)
    }

    func testBeginSaysTheWelcome() async {
        let c = coordinator()
        c.begin()
        await settle(c)
        XCTAssertEqual(spoken, ["Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this."])
    }

    func testEveryStepChangeIsSavedAndSpoken() async {
        let c = coordinator()
        c.begin(); await settle(c)
        c.next(); await settle(c)
        XCTAssertEqual(c.model.step, .colour)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(spoken.count, 2)

        c.choose(colour: "teal"); await settle(c)
        XCTAssertEqual(saves, 2, "a colour is worth keeping")
        XCTAssertEqual(spoken.count, 2, "but trying colours on does not make Saathi repeat itself")
    }

    func testAnEventThatChangesNothingSavesAndSaysNothing() async {
        let c = coordinator()
        c.begin(); await settle(c)
        c.skipDemo(); c.answer("Asha"); c.keysHeld()
        await settle(c)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(spoken.count, 1)
    }

    // MARK: permissions

    func testAGrantedPermissionMovesOnAndTheNextReasonIsSpoken() async {
        let c = coordinator()
        await toPermissions(c)
        XCTAssertEqual(c.model.step, .permission(.microphone))
        c.requestCurrentPermission(); await settle(c)
        XCTAssertEqual(c.model.step, .permission(.speechRecognition))
        XCTAssertEqual(spoken.last, Permission.speechRecognition.reason)
    }

    func testADeniedPermissionMovesOnToo() async {
        permissionAnswers[.microphone] = .denied
        let c = coordinator()
        await toPermissions(c)
        c.requestCurrentPermission(); await settle(c)
        XCTAssertEqual(c.model.step, .permission(.speechRecognition))
        XCTAssertEqual(c.model.deniedPermissions, [.microphone])
        XCTAssertTrue(openedSettings.isEmpty, "a refusal is an answer, not an invitation to System Settings")
    }

    /// Input Monitoring is a switch in System Settings: the card waits there rather than moving on
    /// as if the learner had said no.
    func testInputMonitoringOpensSettingsAndWaitsOnTheCard() async {
        permissionAnswers[.inputMonitoring] = .notDetermined
        let c = coordinator()
        await toPermissions(c)
        c.requestCurrentPermission(); await settle(c)
        c.requestCurrentPermission(); await settle(c)
        c.requestCurrentPermission(); await settle(c)

        XCTAssertEqual(c.model.step, .permission(.inputMonitoring))
        XCTAssertEqual(c.waitingOnSettings, .inputMonitoring)
        XCTAssertEqual(openedSettings, [.inputMonitoring])

        liveStatus[.inputMonitoring] = .granted
        c.settlePermissionFromSettings(); await settle(c)
        XCTAssertNil(c.waitingOnSettings)
        XCTAssertEqual(c.model.step, .allSet)
        XCTAssertEqual(c.model.deniedPermissions, [])
    }

    func testSkippingFromSettingsRecordsThatItIsStillOff() async {
        permissionAnswers[.inputMonitoring] = .notDetermined
        let c = coordinator()
        await toPermissions(c)
        for _ in 0..<3 { c.requestCurrentPermission(); await settle(c) }
        c.settlePermissionFromSettings(); await settle(c)
        XCTAssertEqual(c.model.step, .allSet)
        XCTAssertEqual(c.model.deniedPermissions, [.inputMonitoring])
    }

    // MARK: listening and answering

    func testATranscriptIsProofOfBeingHeardOnTheMicCheckAndAnAnswerOnAQuestion() async {
        let c = coordinator()
        await toPermissions(c)
        for _ in 0..<3 { c.requestCurrentPermission(); await settle(c) }
        c.next()
        XCTAssertEqual(c.model.step, .demo(.micCheck))
        c.heard("hello saathi")
        XCTAssertEqual(c.bubble, "hello saathi")
        XCTAssertTrue(c.model.canContinue)

        c.next(); c.keysHeld(); c.next()
        XCTAssertEqual(c.model.step, .demo(.question(.name)))
        XCTAssertEqual(c.bubble, "", "the bubble does not carry one step's words onto the next")
        c.heard("my name is asha")
        XCTAssertEqual(c.model.answers.name, "Asha")
    }

    func testATranscriptOutsideTheListeningStepsIsNotFirstRunsBusiness() async {
        let c = coordinator()
        c.begin()
        c.heard("hello")
        XCTAssertEqual(c.bubble, "")
        XCTAssertEqual(c.model.step, .welcome)
    }

    /// "Good to meet you, Asha." comes before "What do you want to learn?", not after and not
    /// instead.
    func testTheAcknowledgementIsSpokenBeforeTheNextQuestion() async {
        let c = coordinator()
        await toQuestions(c)
        spoken.removeAll()
        c.answer("Asha"); await settle(c)
        XCTAssertEqual(spoken, ["Good to meet you, Asha.", "What do you want to learn, or play with, first?"])
    }

    func testAReaskIsSpokenWithoutAnAcknowledgement() async {
        let c = coordinator()
        await toQuestions(c)
        c.answer("Asha"); c.answer("the tabla"); await settle(c)
        spoken.removeAll()
        c.answer("whatever"); await settle(c)
        XCTAssertEqual(spoken.count, 1)
        XCTAssertTrue(spoken[0].hasPrefix("Sorry"))
    }

    // MARK: the trial

    private func toTrial(_ c: OnboardingCoordinator) async {
        await toQuestions(c)
        c.answer("Asha"); c.answer("the tabla"); c.answer("plain"); c.answer("Tamil")
        await settle(c)
        XCTAssertEqual(c.model.step, .demo(.trialChat))
    }

    func testTheDisclosureIsSpokenBeforeAnythingIsAskedOfTheBackend() async {
        let c = coordinator()
        await toTrial(c)
        XCTAssertEqual(spoken.last, OnboardingScript.hostedDisclosure)
        XCTAssertEqual(trialChat, [], "nothing is switched to hosted until the learner presses the button")
    }

    func testAnIssuedTrialSwitchesTheVoiceToHostedAndLeavingSwitchesItBack() async {
        let c = coordinator()
        await toTrial(c)
        c.startTrial(); await settle(c)
        XCTAssertEqual(c.model.trial, .ready)
        XCTAssertEqual(trialChat, [true])

        c.next(); await settle(c)
        XCTAssertEqual(c.model.step, .demo(.providerChoice))
        XCTAssertEqual(trialChat, [true, false])
        XCTAssertEqual(c.model.availableProviderChoices, [.hosted, .local, .ownKey])
    }

    func testARefusedTrialIsSaidInTheBackendsWordsAndHostedIsNeverOffered() async {
        trialError = TrialError.refused("that is five trial requests from this network today; try again tomorrow")
        let c = coordinator()
        await toTrial(c)
        c.startTrial(); await settle(c)

        XCTAssertEqual(c.model.trial, .failed("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertTrue(spoken.last?.contains("five trial requests") ?? false)
        XCTAssertEqual(trialChat, [])
        XCTAssertFalse(c.isBusy, "the card can be used again: Try again, or Skip")

        c.skipTrial(); await settle(c)
        XCTAssertEqual(c.model.availableProviderChoices, [.local, .ownKey])
    }

    /// The request takes seconds. Closing the card meanwhile must not leave Saathi streaming to the
    /// hosted service with nothing on screen saying so and nothing to turn it off.
    func testATrialThatArrivesAfterTheCardWasClosedTurnsNothingOn() async {
        trialDelay = 80_000_000
        let c = coordinator()
        await toTrial(c)
        c.startTrial()
        await Task.yield()
        c.close()
        try? await Task.sleep(nanoseconds: 160_000_000)
        await settle(c)
        XCTAssertEqual(trialChat, [], "hosted voice was switched on for a card that no longer exists")
        XCTAssertEqual(finishes.count, 1)
    }

    func testSkippingTheDemoWhileTheTrialIsBeingSetUpTurnsNothingOnEither() async {
        trialDelay = 80_000_000
        let c = coordinator()
        await toTrial(c)
        c.startTrial()
        await Task.yield()
        c.skipDemo()
        try? await Task.sleep(nanoseconds: 160_000_000)
        await settle(c)
        XCTAssertEqual(trialChat, [])
        XCTAssertEqual(c.model.step, .finished)
    }

    /// `false` only ever follows a `true`: leaving the card after a skip or a refusal must not tear
    /// down and rebuild an identical session, during which a key press is refused.
    func testLeavingTheTrialCardWithoutAChatSwapsNothing() async {
        let c = coordinator()
        await toTrial(c)
        c.skipTrial(); await settle(c)
        XCTAssertEqual(trialChat, [])
    }

    /// When first run ends from inside the chat, the app starts a fresh session anyway; a swap
    /// back to listening would only race it, and a reconfigure that loses that race does nothing.
    func testFinishingFromInsideTheChatDoesNotSwapBackFirst() async {
        let c = coordinator()
        await toTrial(c)
        c.startTrial(); await settle(c)
        XCTAssertEqual(trialChat, [true])
        c.skipDemo(); await settle(c)
        XCTAssertEqual(trialChat, [true])
        XCTAssertEqual(finishes.count, 1)
    }

    func testAPermissionAnswerThatArrivesAfterClosingSaysAndChangesNothing() async {
        permissionDelay = 80_000_000
        let c = coordinator()
        await toPermissions(c)
        c.requestCurrentPermission()
        await Task.yield()
        c.close()
        let said = spoken.count
        try? await Task.sleep(nanoseconds: 160_000_000)
        await settle(c)
        XCTAssertEqual(c.model.step, .permission(.microphone))
        XCTAssertEqual(spoken.count, said, "a line was spoken for a card nobody can see")
    }

    // MARK: the mic check listens by itself

    private func toMicCheck(_ c: OnboardingCoordinator) async {
        await toPermissions(c)
        for _ in 0..<3 { c.requestCurrentPermission(); await settle(c) }
        c.next(); await settle(c)
        XCTAssertEqual(c.model.step, .demo(.micCheck))
    }

    /// The keys are taught on the *next* card, so this one has to open a turn itself — and only
    /// once Saathi has stopped talking, or the first thing it hears is its own voice.
    func testTheMicCheckListensOnceTheLineHasBeenSpokenAndStopsByItself() async {
        let c = coordinator()
        c.listenFor = 0.05
        await toMicCheck(c)
        XCTAssertEqual(listening, [true])
        XCTAssertTrue(c.isListening)
        XCTAssertEqual(spoken.last, "Can I hear you? Say anything. You'll see the bars move, and I'll show you what I heard.")

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(listening, [true, false], "stopping is what makes the session hand over a transcript")
        XCTAssertFalse(c.isListening)

        c.heard("hello"); c.next(); await settle(c)
        XCTAssertEqual(c.model.step, .demo(.holdToTalk))
        XCTAssertEqual(listening, [true, false], "the next card is the keys' job")
    }

    func testLeavingTheMicCheckWhileListeningClosesTheTurn() async {
        let c = coordinator()
        c.listenFor = 5
        await toMicCheck(c)
        c.skipDemo(); await settle(c)
        XCTAssertEqual(listening, [true, false])
    }

    /// The bars rise at once and fall slowly — bars that drop to nothing between syllables flicker —
    /// and what has been made out so far shows before the turn has ended.
    func testTheBarsAndTheLiveWordsFollowAnOpenTurnAndRestWhenItEnds() async {
        let c = coordinator()
        c.listenFor = 5
        await toMicCheck(c)
        c.listening(level: 0.8, partial: nil)
        XCTAssertEqual(c.level, 0.8, accuracy: 0.001)
        c.listening(level: 0.1, partial: "hello sa")
        XCTAssertEqual(c.level, 0.64, accuracy: 0.001, "down slowly")
        XCTAssertEqual(c.bubble, "hello sa")
        XCTAssertFalse(c.model.heardSomething, "a preview is not yet being heard: the turn has not ended")

        c.heard("hello saathi")
        XCTAssertEqual(c.level, 0)
        XCTAssertEqual(c.bubble, "hello saathi")
        XCTAssertTrue(c.model.canContinue)
    }

    func testLevelsOutsideTheListeningCardsAreIgnored() async {
        let c = coordinator()
        c.begin()
        c.listening(level: 0.9, partial: "hello")
        XCTAssertEqual(c.level, 0)
        XCTAssertEqual(c.bubble, "")
    }

    /// A room too quiet to transcribe is not a locked door.
    func testTwoEmptyListensStopInsisting() async {
        let c = coordinator()
        c.listenFor = 0.02
        await toMicCheck(c)
        XCTAssertFalse(c.model.canContinue)
        c.heardNothing()
        XCTAssertFalse(c.model.canContinue)
        c.heardNothing()
        XCTAssertTrue(c.model.canContinue)
    }

    // MARK: the end

    func testFinishingIsReportedExactlyOnce() async {
        let c = coordinator()
        await toTrial(c)
        c.skipTrial(); c.choose(provider: .local); await settle(c)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.providerChoice, .local)
        c.close()
        XCTAssertEqual(finishes.count, 1)
    }

    func testClosingTheWindowHalfwayFinishesWithoutClaimingToBeOnboarded() async {
        let c = coordinator()
        await toQuestions(c)
        c.answer("Asha"); await settle(c)
        c.close()
        XCTAssertEqual(finishes.count, 1)
        var configuration = SaathiConfiguration()
        finishes[0].apply(to: &configuration)
        XCTAssertEqual(configuration.name, "Asha")
        XCTAssertNil(configuration.onboarded, "first run comes back next launch")
    }

    func testSkipDemoFinishes() async {
        let c = coordinator()
        await toQuestions(c)
        c.skipDemo(); await settle(c)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes[0].step, .finished)
    }
}

@MainActor
final class OnboardingCardWordingTests: XCTestCase {

    /// Saathi says the title and the sentence as one breath; the card prints the title once.
    func testTheSubtitleDoesNotRepeatTheTitle() {
        XCTAssertEqual(
            OnboardingCardView.subtitle(for: OnboardingLine(
                title: "Namaste", spoken: "Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this.")),
            "I'm Saathi, a companion for learning new things. I'll talk you through this.")
        XCTAssertEqual(
            OnboardingCardView.subtitle(for: OnboardingLine(
                title: "This is how you talk to me.", spoken: "This is how you talk to me. Hold control and option, and say hi.")),
            "Hold control and option, and say hi.")
        XCTAssertEqual(
            OnboardingCardView.subtitle(for: OnboardingLine(title: "All set", spoken: "Turn your sound on. Meet Saathi.")),
            "Turn your sound on. Meet Saathi.")
    }

    func testAQuestionThatIsItsOwnTitleSaysHowToAnswerInstead() {
        XCTAssertEqual(
            OnboardingCardView.subtitle(for: OnboardingLine(title: "What should I call you?", spoken: "What should I call you?")),
            "Say it, or type it.")
    }

    func testTheCardsFaceFollowsWhatTheCardIsDoing() {
        var model = OnboardingModel(supportedLanguages: ["en-IN"], palette: ["blue"])
        XCTAssertEqual(OnboardingWindowController.expression(for: model, isSpeaking: false), .idle)
        XCTAssertEqual(OnboardingWindowController.expression(for: model, isSpeaking: true), .dictating)
        for event: OnboardingEvent in [.next, .next, .next,
                      .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
                      .permissionResolved(.inputMonitoring, .granted), .next] { model.handle(event) }
        XCTAssertEqual(OnboardingWindowController.expression(for: model, isSpeaking: false), .listening)
    }
}

@MainActor
final class OnboardingEntryTests: XCTestCase {

    /// `onboarded` did not exist before contract 0.8.0, so every working install has it unset.
    /// Greeting someone who has used Saathi for weeks with "Namaste, I'm Saathi" is not first run.
    func testFirstRunShowsItselfOnlyToAnInstallWithNothingConfigured() {
        XCTAssertTrue(AppController.shouldOnboard(SaathiConfiguration()))
        XCTAssertTrue(AppController.shouldOnboard(SaathiConfiguration(onboarded: false)))
        XCTAssertFalse(AppController.shouldOnboard(SaathiConfiguration(onboarded: true)))
        XCTAssertFalse(AppController.shouldOnboard(SaathiConfiguration(openaiKey: "sk-works")))
        XCTAssertFalse(AppController.shouldOnboard(SaathiConfiguration(token: "saathi_live")))
    }

    /// Quit halfway through: a colour and a name are on disk, `onboarded` is not. It comes back.
    func testAnInterruptedFirstRunComesBack() {
        XCTAssertTrue(AppController.shouldOnboard(SaathiConfiguration(name: "Asha", colour: "teal")))
    }
}


final class OnboardingBarsTests: XCTestCase {

    func testBarsRestSmallAndTheMiddleOneIsTallest() {
        XCTAssertEqual(OnboardingCardView.barHeight(level: 0, shape: 1), 4)
        XCTAssertEqual(OnboardingCardView.barHeight(level: 1, shape: 1), 30)
        XCTAssertEqual(OnboardingCardView.barHeight(level: 7, shape: 1), 30, "clamped")
        XCTAssertLessThan(
            OnboardingCardView.barHeight(level: 0.5, shape: OnboardingCardView.barShape[0]),
            OnboardingCardView.barHeight(level: 0.5, shape: OnboardingCardView.barShape[2]))
    }
}
