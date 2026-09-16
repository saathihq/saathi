//
//  CompanionStateTests.swift
//  SaathiKitTests
//
//  The face follows the voice session. These pin the folding of session events into a state,
//  with time passed in rather than read, so every transition is a plain function of its inputs.
//

import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class CompanionStateTests: XCTestCase {

    private var machine = CompanionStateMachine(now: 1_000)

    func testHoldingTheKeysListensAndReleasingThinks() {
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_001), .listening)
        XCTAssertEqual(machine.apply(.keysReleased, now: 1_003), .thinking)
    }

    func testReleasingTheKeysWhenNotListeningChangesNothing() {
        XCTAssertEqual(machine.apply(.keysReleased, now: 1_001), .idle)
    }

    func testTheLanesStatusLinesDriveTheState() {
        XCTAssertEqual(machine.apply(.status("listening…"), now: 1_001), .listening)
        XCTAssertEqual(machine.apply(.status("thinking…"), now: 1_002), .thinking)
        XCTAssertEqual(machine.apply(.status("ready — on-device speech recognition (en_US)"), now: 1_003), .thinking, "a readiness note is not a state")
        XCTAssertEqual(machine.apply(.status("did not catch that"), now: 1_004), .alert("did not catch that"))
    }

    func testAnAlertGivesWayToIdleAfterTwiceTheIdleDelay() {
        machine.apply(.failure("no model reachable"), now: 1_000)
        XCTAssertEqual(machine.state, .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_003), .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_004), .idle)
    }

    func testSpeakingThenSilenceSettlesToIdleAfterTheDelay() {
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000), .speaking)
        XCTAssertEqual(machine.apply(.speakingChanged(false), now: 1_005), .speaking, "the face holds for a moment")
        XCTAssertEqual(machine.tick(now: 1_006.9), .speaking)
        XCTAssertEqual(machine.tick(now: 1_007), .idle)
    }

    func testARealtimeReplyCountsAsSpeaking() {
        XCTAssertEqual(machine.apply(.saathiSpoke("Sure."), now: 1_000), .speaking)
        XCTAssertEqual(machine.tick(now: 1_002), .idle)
    }

    func testAStepShowsAndKeepsShowingWhileNarrated() {
        let step = ShowStepAction(title: "Open the lid", index: 2, total: 3)
        XCTAssertEqual(machine.apply(.action(.showStep(step)), now: 1_000), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000.1), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.apply(.speakingChanged(false), now: 1_004), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.tick(now: 1_006), .idle)
    }

    func testTheLastStepCelebrates() {
        let last = ShowStepAction(title: "Tell Saathi how that went", index: 3, total: 3)
        XCTAssertEqual(machine.apply(.action(.showStep(last)), now: 1_000), .celebrating)
    }

    func testASayActionWaitsForTheSpeakerToReport() {
        XCTAssertEqual(machine.apply(.action(.say(SayAction(text: "Hi"))), now: 1_000), .idle)
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000.1), .speaking)
    }

    func testQuietForThreeMinutesFallsAsleepAndAnyEventWakes() {
        XCTAssertEqual(machine.tick(now: 1_179), .idle)
        XCTAssertEqual(machine.tick(now: 1_180), .asleep)
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_181), .listening)
    }

    func testTheUsersWordsMeanThinking() {
        machine.apply(.keysHeld, now: 1_000)
        XCTAssertEqual(machine.apply(.userSpoke("hello"), now: 1_002), .thinking)
    }

    func testPoweringDownIsTerminal() {
        XCTAssertEqual(machine.apply(.quit, now: 1_000), .poweringDown)
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_001), .poweringDown)
        XCTAssertEqual(machine.tick(now: 2_000), .poweringDown)
    }

    func testTheWords() {
        XCTAssertEqual(CompanionState.idle.word, "Ready")
        XCTAssertEqual(CompanionState.showingStep(index: 2, total: 5).word, "Step 2 of 5")
        XCTAssertEqual(CompanionState.alert("no model reachable").word, "no model reachable")
        XCTAssertEqual(CompanionState.poweringDown.word, "Bye")
    }

    func testAStrayKeyReleaseDoesNotStrandTheFaceInSpeaking() {
        machine.apply(.speakingChanged(true), now: 1_000)
        machine.apply(.speakingChanged(false), now: 1_005)
        XCTAssertEqual(machine.apply(.keysReleased, now: 1_006), .speaking, "a no-op")
        XCTAssertEqual(machine.tick(now: 1_007), .idle, "the settle survived the no-op")
        XCTAssertEqual(machine.tick(now: 1_186), .asleep, "and so did falling asleep afterwards")
    }

    func testAReadinessNoteDuringAnAlertDoesNotShortenIt() {
        machine.apply(.failure("no model reachable"), now: 1_000)
        XCTAssertEqual(machine.apply(.status("ready — on-device speech recognition (en_US)"), now: 1_001), .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_003.9), .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_004), .idle)
    }
}
