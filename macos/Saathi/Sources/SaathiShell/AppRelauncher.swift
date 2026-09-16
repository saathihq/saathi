//
//  AppRelauncher.swift
//  SaathiShell
//
//  Bringing Saathi back ourselves, rather than trusting Quit & Reopen.
//
//  macOS asks an app that requests Input Monitoring to quit and reopen, and relaunches it through
//  LaunchServices by code signature. An ad-hoc signed build has no stable identity to come back to —
//  its cdhash changes on every build — so it is killed and never reopened. A properly signed build
//  fixes that, and this exists so the app does not depend on it: the grant takes effect either way.
//
//  The ordering is the whole point. Terminating before the new instance is confirmed launched is a
//  quit with no reopen, which is precisely the bug being replaced.
//

import AppKit
import Foundation

/// Internal, not public: the only caller is `AppController` in this module, and nothing outside
/// `SaathiShell` should be able to terminate the app. (Also required to compile: a public
/// `relaunch` cannot default its `launch` parameter to the private `launchAnother`.)
enum AppRelauncher {

    /// Launches a fresh instance and, only once it is confirmed running, ends this one.
    ///
    /// `launch` and `terminate` are injected so the ordering rule can be tested without actually
    /// relaunching the test runner. `@MainActor` because the default `terminate` calls into AppKit
    /// (`NSApp.terminate`), which — like the rest of AppKit — must run on the main thread; this is
    /// the one code path whose entire job is shutting the app down, so it must not do that off-main.
    @MainActor
    @discardableResult
    static func relaunch(
        bundleURL: URL,
        launch: @MainActor (URL) async -> Bool = Self.launchAnother,
        terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    ) async -> Bool {
        let launched = await launch(bundleURL)
        guard launched else { return false }
        terminate()
        return true
    }

    /// `createsNewApplicationInstance` is required: without it AppKit sees a running instance with
    /// this bundle id and simply activates us, so nothing is relaunched and we then quit.
    @MainActor
    private static func launchAnother(_ bundleURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
