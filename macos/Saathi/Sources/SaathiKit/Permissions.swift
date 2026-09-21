//
//  Permissions.swift
//  SaathiKit
//
//  The four things Saathi asks macOS for, each with the one-line reason it gives, so the shell,
//  onboarding and the menu all say the same words.
//

import AVFoundation
import CoreGraphics
import Foundation
import Speech

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public enum Permission: CaseIterable, Hashable, Sendable {
    case microphone
    case speechRecognition
    case inputMonitoring
    case screenRecording

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// Spoken and shown when asking. One line, Saathi's voice.
    public var reason: String {
        switch self {
        case .microphone: return "This lets me hear you. Only while you hold the keys."
        case .speechRecognition: return "Turns your voice into words on this Mac. Nothing is sent anywhere."
        case .inputMonitoring: return "Lets me notice when you hold control and option, in any app."
        case .screenRecording: return "Lets me look at your screen, only when you ask about something on it."
        }
    }


    /// An SF Symbol for the permission, so it can be shown as a tile rather than a row of words.
    public var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "eye"
        }
    }

    /// The System Settings pane that holds the switch.
    public var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

public enum Permissions {

    public static func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return map(SFSpeechRecognizer.authorizationStatus())
        case .inputMonitoring:
            // The API answers yes or no; it cannot tell "refused" from "never asked".
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .screenRecording:
            // Same shape as Input Monitoring: yes or no, never "refused". Without this check the
            // capture ran regardless and came back as a picture of the wallpaper, which the
            // vision model then described with a straight face.
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    /// Prompts if the system will, then reports what it decided.
    public static func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return status(of: .microphone)
        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: map($0)) }
            }
        case .inputMonitoring:
            return CGRequestListenEventAccess() ? .granted : .notDetermined
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
