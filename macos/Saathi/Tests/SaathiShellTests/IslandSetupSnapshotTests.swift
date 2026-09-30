//
//  IslandSetupSnapshotTests.swift
//  SaathiShellTests
//
//  The Setup tab, drawn to a PNG, for eyes rather than assertions: the three key rows, the
//  sentence under them, the note, the picker and the switch. Opt-in, like the first-run cards:
//
//      SAATHI_SNAPSHOTS=/some/dir swift test --filter IslandSetupSnapshotTests
//
//  Nothing is put on screen. The view is laid out in an offscreen hosting view, tall enough that
//  nothing has to be scrolled to, over the island's own black. The model is filled by the same
//  static wording the app uses, so what is drawn is what would be said.
//

import AppKit
import SwiftUI
import XCTest
import SaathiContract
import SaathiKit
@testable import SaathiShell

@MainActor
final class IslandSetupSnapshotTests: XCTestCase {

    private struct Shot {
        let name: String
        let configuration: SaathiConfiguration
    }

    func testDrawTheSetupTab() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SAATHI_SNAPSHOTS"], !directory.isEmpty else {
            throw XCTSkip("set SAATHI_SNAPSHOTS=<dir> to draw the Setup tab")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // None of these is a key: they are shapes with four characters on the end to mask.
        let openAI = "sk-openai-not-a-key-u6MA"
        let anthropic = "sk-ant-not-a-key-9xQ2"
        let sarvam = "sk_sarvam_not_a_key_Lm4t"
        let shots = [
            Shot(name: "setup-1-fresh", configuration: SaathiConfiguration()),
            Shot(name: "setup-2-openai", configuration: SaathiConfiguration(provider: .openai, openaiKey: openAI)),
            Shot(name: "setup-3-sarvam-heard-and-spoken", configuration: SaathiConfiguration(
                provider: .sarvam, openaiKey: openAI, anthropicKey: anthropic, sarvamKey: sarvam,
                speech: .sarvam, language: "ml")),
            Shot(name: "setup-4-claude-with-sarvams-ears", configuration: SaathiConfiguration(
                provider: .anthropic, anthropicKey: anthropic, sarvamKey: sarvam, speech: .sarvam, language: "hi")),
            Shot(name: "setup-5-sarvam-thinking-only", configuration: SaathiConfiguration(
                provider: .sarvam, apiKey: sarvam, language: "hi")),
            Shot(name: "setup-6-sarvam-in-french", configuration: SaathiConfiguration(
                provider: .sarvam, sarvamKey: sarvam, speech: .sarvam, language: "fr")),
        ]

        let size = CGSize(width: NotchPanel.openWidth, height: 1240)
        for shot in shots {
            let model = IslandModel()
            model.tab = .setup
            model.keyStates = AppController.seededKeyStates(for: shot.configuration)
            AppController.describe(shot.configuration, on: model)
            let plan = AppController.setupPlan(typed: [], states: model.keyStates, configuration: shot.configuration)
            model.planExplanation = plan.explanation
            model.keysNote = AppController.keysNote(for: plan, language: shot.configuration.resolvedLanguage)
            model.permissions = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.granted) })
            model.lastYouSaid = "ഇത് എന്താണ്?"
            model.lastSaathiSaid = "ഇത് ഒരു സ്പ്രെഡ്ഷീറ്റ് ആണ്."

            let staged = IslandSetupView(display: IslandDisplay(), model: model, actions: IslandActions())
                .padding(.top, 16)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.black)
                .preferredColorScheme(.dark)

            let hosting = NSHostingView(rootView: staged)
            hosting.frame = NSRect(origin: .zero, size: size)
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
