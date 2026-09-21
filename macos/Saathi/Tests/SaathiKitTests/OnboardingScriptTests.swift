//
//  OnboardingScriptTests.swift
//  SaathiKitTests
//
//  "Everything on a card is also spoken." These pin the sentences the spec wrote out, and check
//  that no step anywhere in first run is reached with nothing to say.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingScriptTests: XCTestCase {

    private func model(after events: [OnboardingEvent]) -> OnboardingModel {
        var m = OnboardingModel(supportedLanguages: ["en-IN", "ta-IN"], palette: ["blue", "teal"])
        for event in events { m.handle(event) }
        return m
    }

    private let toAllSet: [OnboardingEvent] = [
        .next, .next, .next,
        .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
        .permissionResolved(.inputMonitoring, .granted),
    ]
    private var toTrial: [OnboardingEvent] {
        toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next,
                    .answered("Asha"), .answered("the tabla"), .answered("plain"), .answered("Tamil")]
    }

    func testTheSentencesTheSpecWroteOutAreSpokenVerbatim() {
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: [])).spoken,
            "Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this.")
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: [.next, .next])).spoken,
            "I live up here now. I need three permissions to get started.")
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: toAllSet)).spoken,
            "Turn your sound on. Meet Saathi.")
        XCTAssertEqual(
            OnboardingScript.hostedDisclosure,
            "For this chat I'll use Saathi's hosted service. Your voice goes to Saathi's servers and its "
                + "provider for these minutes. After this you choose where I think.")
        XCTAssertEqual(OnboardingScript.inputMonitoringHelper, "I'm Saathi. Turn me on in the list.")
    }

    func testTheDemoCardsCarryTheSpecsTitles() {
        XCTAssertEqual(OnboardingScript.line(for: model(after: toAllSet + [.next])).title, "Can I hear you?")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toAllSet + [.next, .heard("hi"), .next])).title, "This is how you talk to me.")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial)).title, "Talk to me properly.")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial + [.skipTrial])).title, "Where should I think from now on?")
    }

    /// One source of truth: the reason on the permission step is the reason everywhere else.
    func testAPermissionStepSaysThatPermissionsOwnReason() {
        let line = OnboardingScript.line(for: model(after: [.next, .next, .next]))
        XCTAssertEqual(line.title, "Microphone")
        XCTAssertEqual(line.spoken, Permission.microphone.reason)
    }

    func testTheTrialStepSaysTheDisclosureBeforeAndTheExactReasonAfterARefusal() {
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial)).spoken, OnboardingScript.hostedDisclosure)

        let refused = model(after: toTrial + [.trialRequested, .trialFailed("that is five trial requests from this network today; try again tomorrow")])
        let line = OnboardingScript.line(for: refused)
        XCTAssertTrue(line.spoken.contains("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertTrue(line.spoken.contains("skip"), "the refusal offers the way on")
        XCTAssertEqual(line.tone, .calm)
    }

    func testAReaskIsWordedDifferentlyFromTheFirstAsking() {
        let asking = model(after: toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla")])
        let reasking = model(after: toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla"), .answered("dunno")])
        XCTAssertNotEqual(OnboardingScript.line(for: asking).spoken, OnboardingScript.line(for: reasking).spoken)
        for manner in Manner.allCases {
            XCTAssertTrue(OnboardingScript.line(for: reasking).spoken.contains(manner.title), "the re-ask repeats the choices")
        }
    }

    func testAcknowledgementsUseWhatWasSaidAndSurviveNothingHavingBeenSaid() {
        let answers = OnboardingAnswers(name: "Asha", firstGoal: "the tabla", manner: .calmAndSlow, language: "ta-IN")
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .name, in: answers).contains("Asha"))
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .firstGoal, in: answers).contains("the tabla"))
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .language, in: answers).contains("Tamil"))
        for question in OnboardingQuestion.allCases {
            XCTAssertFalse(OnboardingScript.acknowledgement(of: question, in: answers).isEmpty)
            XCTAssertFalse(OnboardingScript.acknowledgement(of: question, in: OnboardingAnswers()).isEmpty, "\(question) with no answer")
        }
    }

    func testEveryStepHasSomethingToShowAndSomethingToSay() {
        var steps: [OnboardingModel] = [model(after: [])]
        var m = model(after: [])
        for event in toTrial + [.trialRequested, .trialIssued, .next, .choseProvider(.local)] {
            m.handle(event)
            steps.append(m)
        }
        XCTAssertEqual(steps.last?.step, .finished)
        for snapshot in steps {
            let line = OnboardingScript.line(for: snapshot)
            XCTAssertFalse(line.title.isEmpty, "\(snapshot.step) has no title")
            XCTAssertFalse(line.spoken.isEmpty, "\(snapshot.step) has nothing to say")
        }
    }

    func testEveryProviderChoiceSaysWhereTheVoiceGoes() {
        for choice in ProviderChoice.allCases {
            XCTAssertFalse(OnboardingScript.title(for: choice).isEmpty)
            XCTAssertFalse(OnboardingScript.detail(for: choice).isEmpty)
        }
        XCTAssertTrue(OnboardingScript.detail(for: .local).contains("stays on this Mac"))
        XCTAssertTrue(OnboardingScript.detail(for: .hosted).contains("Saathi's servers"))
    }

    func testEveryPermissionHasADeniedNoteThatSaysHowToFixItLater() {
        for permission in OnboardingModel.permissionOrder {
            XCTAssertTrue(OnboardingScript.deniedNote(for: permission).contains("System Settings"), "\(permission)")
        }
    }
}
