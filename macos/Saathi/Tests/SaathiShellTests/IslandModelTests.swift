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
        XCTAssertEqual(IslandModel().openAIKeyState, .empty)
        XCTAssertEqual(IslandModel().anthropicKeyState, .empty)
        XCTAssertEqual(IslandModel().planExplanation, "")
        XCTAssertEqual(IslandModel().unusedKeyNote, "")
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
        model.openAIKeyState = .checking
        XCTAssertEqual(model.openAIKeyState, .checking)
        model.openAIKeyState = .checked(.rejected("OpenAI did not accept that key."))
        XCTAssertEqual(model.openAIKeyState, .checked(.rejected("OpenAI did not accept that key.")))
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
        actions.onCheckKey(.openai, "sk-o")
        actions.onSaveKeys("sk-o", "sk-a")
    }
}

// MARK: - What the panel says after a save

@MainActor
final class SetupPresentationTests: XCTestCase {

    func testAnUnusedStoredKeyIsNamedOutLoud() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let note = AppController.unusedKeyNote(for: plan)
        XCTAssertTrue(note.contains("Anthropic"), "got: \(note)")
        XCTAssertTrue(note.lowercased().contains("nothing uses it") || note.lowercased().contains("not used"),
                      "the note must say it is unused, not merely mention it: \(note)")
    }

    func testThereIsNoNoteWhenEveryStoredKeyIsInUse() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertEqual(AppController.unusedKeyNote(for: plan), "")
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
