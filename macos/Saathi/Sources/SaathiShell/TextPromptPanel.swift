//
//  TextPromptPanel.swift
//  SaathiShell
//
//  The Text shortcut: control tapped twice opens one line to type to Saathi, under the island.
//  Return sends it and closes; Escape, or clicking away, closes without sending.
//
//  Saathi is an accessory app, so to receive typing at all it has to become active — the same
//  reason the Setup tab does (see `NotchPanel.setKeyboardFocus`). The app that was in front is
//  remembered and handed the keyboard back the moment the line is sent, before Saathi answers:
//  a question about "this" is about what is in that app, and a screen look reads the selection
//  from whichever app is in front.
//

import AppKit
import SwiftUI

@MainActor
final class TextPromptPanel: NSPanel {

    private let onSend: (String) -> Void
    private var previous: NSRunningApplication?
    private let model = TextPromptModel()

    init(onSend: @escaping (String) -> Void) {
        self.onSend = onSend
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: TextPromptView(
            model: model,
            onSubmit: { [weak self] text in self?.submit(text) },
            onCancel: { [weak self] in self?.dismiss() }))
    }

    override var canBecomeKey: Bool { true }

    /// Clicking into another app is a cancel, as it is for Spotlight.
    override func resignKey() {
        super.resignKey()
        if isVisible { orderOut(nil); previous = nil }
    }

    var isShowing: Bool { isVisible }

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        let frame = screen.frame
        let top = frame.maxY - (screen.frame.maxY - screen.visibleFrame.maxY) - 90
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: top - self.frame.height))
        model.text = ""
        model.focusToken += 1
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        let previous = self.previous
        self.previous = nil
        orderOut(nil)
        previous?.activate()
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}

@MainActor
final class TextPromptModel: ObservableObject {
    @Published var text = ""
    /// Bumped on every show, so the field takes focus again on a panel that is being reused.
    @Published var focusToken = 0
}

private struct TextPromptView: View {
    @ObservedObject var model: TextPromptModel
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.6))
            TextField("Type to Saathi — Return to send, Esc to close", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit { onSubmit(model.text) }
                .onExitCommand { onCancel() }
        }
        .padding(.horizontal, 16)
        .frame(width: 460, height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
    }
}
