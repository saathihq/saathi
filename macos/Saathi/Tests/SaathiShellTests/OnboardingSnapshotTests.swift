//
//  OnboardingSnapshotTests.swift
//  SaathiShellTests
//
//  Every first-run card, drawn to a PNG, for eyes rather than assertions. Opt-in, because a test
//  run should not scatter images about:
//
//      SAATHI_SNAPSHOTS=/some/dir swift test --filter OnboardingSnapshotTests
//
//  Nothing is put on screen and nothing is spoken: the card is laid out in an offscreen hosting
//  view over a stand-in for the blurred desktop, and the coordinator's effects are all no-ops.
//

import AppKit
import SwiftUI
import XCTest
import SaathiContract
import SaathiKit
import SaathiMascot
@testable import SaathiShell

@MainActor
final class OnboardingSnapshotTests: XCTestCase {

    private struct Shot {
        let name: String
        let events: [OnboardingEvent]
        var bubble: String? = nil
        var permissionAnswers: [Permission: PermissionStatus] = [:]
        var requestPermissionFirst = false
    }

    private let granted: [OnboardingEvent] = [
        .next, .choseColour("teal"), .next, .next,
        .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
        .permissionResolved(.inputMonitoring, .granted),
    ]

    func testDrawEveryCard() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SAATHI_SNAPSHOTS"], !directory.isEmpty else {
            throw XCTSkip("set SAATHI_SNAPSHOTS=<dir> to draw the cards")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let toQuestions = granted + [.next, .heard("hello saathi"), .next, .keysHeld, .next]
        let toTrial = toQuestions + [.answered("Asha"), .answered("the tabla"), .answered("calm and slow"), .answered("Tamil")]
        let shots: [Shot] = [
            Shot(name: "01-welcome", events: []),
            Shot(name: "02-colour", events: [.next, .choseColour("coral")]),
            Shot(name: "03-into-notch", events: [.next, .next]),
            Shot(name: "04-permission-microphone", events: [.next, .next, .next]),
            Shot(name: "05-permission-input-monitoring-waiting",
                 events: [.next, .next, .next, .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted)],
                 permissionAnswers: [.inputMonitoring: .notDetermined], requestPermissionFirst: true),
            Shot(name: "06-all-set", events: granted),
            Shot(name: "07-all-set-with-denials", events: [
                .next, .next, .next, .permissionResolved(.microphone, .denied),
                .permissionResolved(.speechRecognition, .granted), .permissionResolved(.inputMonitoring, .notDetermined)]),
            Shot(name: "08-mic-check", events: granted + [.next, .heard("hello saathi")], bubble: "hello saathi"),
            Shot(name: "09-hold-to-talk", events: granted + [.next, .heard("hi"), .next]),
            Shot(name: "10-question-name", events: toQuestions),
            Shot(name: "11-question-manner", events: toQuestions + [.answered("Asha"), .answered("the tabla")]),
            Shot(name: "12-question-language", events: toQuestions + [.answered("Asha"), .answered("the tabla"), .answered("plain")]),
            Shot(name: "13-trial-disclosure", events: toTrial),
            Shot(name: "14-trial-refused", events: toTrial + [.trialRequested, .trialFailed("that is five trial requests from this network today; try again tomorrow")]),
            Shot(name: "15-provider-with-hosted", events: toTrial + [.trialRequested, .trialIssued, .next]),
            Shot(name: "16-provider-without-hosted", events: toTrial + [.skipTrial]),
        ]

        let data = try MascotData.load()
        for shot in shots {
            var model = OnboardingModel(supportedLanguages: ["en-IN", "hi-IN", "ta-IN", "ml-IN", "ko-KR"], palette: Array(data.palette.keys))
            for event in shot.events { model.handle(event) }

            var effects = OnboardingEffects()
            effects.requestPermission = { shot.permissionAnswers[$0] ?? .granted }
            let coordinator = OnboardingCoordinator(model: model, effects: effects)
            if shot.requestPermissionFirst {
                coordinator.requestCurrentPermission()
                for _ in 0..<5 { await Task.yield() }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            if let bubble = shot.bubble { coordinator.heard(bubble) }

            let colour = MascotColor(paletteName: model.colour ?? "blue", in: data) ?? MascotColor(hex: "#377FE6")
            let mascot = MascotView(data: data, color: colour, expression: OnboardingWindowController.expression(for: model, isSpeaking: false),
                                    frame: NSRect(x: 0, y: 0, width: 96, height: 96))
            mascot.animates = false

            let card = OnboardingCardView(
                coordinator: coordinator, mascot: mascot,
                palette: OnboardingWindowController.orderedPalette(data),
                languages: [("en-IN", "English"), ("hi-IN", "Hindi"), ("ta-IN", "Tamil"), ("ml-IN", "Malayalam"), ("ko-KR", "Korean")],
                startAtLogin: .constant(true))

            // A stand-in for the blurred desktop the real window sits over.
            let staged = ZStack {
                LinearGradient(colors: [Color(hex: "#3B2A6B"), Color(hex: "#141821")], startPoint: .top, endPoint: .bottom)
                card
            }
            .frame(width: 720, height: 560)
            .preferredColorScheme(.dark)

            let hosting = NSHostingView(rootView: staged)
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
            hosting.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(shot.name).png"))
        }
    }
}
