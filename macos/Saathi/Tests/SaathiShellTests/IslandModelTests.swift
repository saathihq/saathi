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
