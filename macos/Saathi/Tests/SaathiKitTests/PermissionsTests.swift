//
//  PermissionsTests.swift
//  SaathiKitTests
//

import AVFoundation
import Speech
import XCTest
@testable import SaathiKit

final class PermissionsTests: XCTestCase {

    func testEveryPermissionExplainsItselfAndKnowsItsSettingsPane() {
        for permission in Permission.allCases {
            XCTAssertFalse(permission.title.isEmpty)
            XCTAssertFalse(permission.reason.isEmpty, "\(permission) has no reason")
            XCTAssertEqual(permission.settingsURL.scheme, "x-apple.systempreferences", "\(permission)")
            XCTAssertTrue(permission.settingsURL.absoluteString.contains("Privacy_"), "\(permission)")
        }
    }

    func testMicrophoneStatusesMap() {
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.restricted), .denied)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testSpeechStatusesMap() {
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.denied), .denied)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.restricted), .denied)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testStatusOfInputMonitoringNeverThrowsAndIsNeverDenied() {
        // The API cannot tell "asked and refused" from "never asked", so we never claim denied.
        XCTAssertNotEqual(Permissions.status(of: .inputMonitoring), .denied)
    }
}
