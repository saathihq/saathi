//
//  IslandModelTests.swift
//  SaathiShellTests
//
//  The Home panel's model, checked without a window, a menu or a voice session behind it.
//

import XCTest
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
