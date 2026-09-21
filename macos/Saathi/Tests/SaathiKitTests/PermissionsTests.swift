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

    /// Looking at the screen needs Screen Recording, and until now nothing asked for it: the
    /// capture ran without the grant and came back as a picture of the wallpaper.
    func testScreenRecordingIsOneOfTheThingsSaathiAsksFor() {
        XCTAssertTrue(Permission.allCases.contains(.screenRecording))
        XCTAssertEqual(Permission.screenRecording.title, "Screen Recording")
        XCTAssertTrue(Permission.screenRecording.settingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
        // Like Input Monitoring, the API answers yes or no, so "denied" is never claimed.
        XCTAssertNotEqual(Permissions.status(of: .screenRecording), .denied)
    }

    func testStatusOfInputMonitoringNeverThrowsAndIsNeverDenied() {
        // The API cannot tell "asked and refused" from "never asked", so we never claim denied.
        XCTAssertNotEqual(Permissions.status(of: .inputMonitoring), .denied)
    }

    /// Accessibility is what tells forty identical rows apart. Sight works without it, so it is
    /// offered, never counted as missing.
    func testAccessibilityIsOfferedButNeverRequired() {
        XCTAssertTrue(Permission.allCases.contains(.accessibility))
        XCTAssertTrue(Permission.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        XCTAssertNotEqual(Permissions.status(of: .accessibility), .denied)
        XCTAssertEqual(Permission.allCases.filter(\.isRequired), [.microphone, .speechRecognition, .inputMonitoring])
    }
}
