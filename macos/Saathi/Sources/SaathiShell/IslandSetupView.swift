//
//  IslandSetupView.swift
//  SaathiShell
//
//  The island's Settings tab, behind the gear — OpenClicky's `NotchSettingsView`, ported: a scroll
//  of titled sections, each a rounded card of rows, with one row idiom (icon, title, value) and
//  three variants of it (a switch, a tappable row with a chevron, a key field).
//
//  The two keys are rows here rather than a screen of their own. They were a panel with two big
//  fields and a Save button, which is a different kind of surface from everything else Saathi shows
//  about itself — and it meant the one place that says where your voice goes was somewhere you had
//  to leave the settings to find.
//
//  The view holds the text being typed and nothing else. Validation, the plan and the file all live
//  behind the actions, so this file can be looked at and changed without touching anything that can
//  leak a key.
//

import AppKit
import SaathiContract
import SaathiKit
import SwiftUI

struct IslandSetupView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    /// Held here rather than in the model: a key being typed is not application state, and keeping
    /// it out of the observable object means it is never published to anything else.
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    /// The saved rows that have been reopened for a new key, each with the masked form it showed,
    /// so "Keep" can put the line back. View-local, like the text: reopening a row is not a verdict
    /// about the key, and it must not touch the model's `.saved` — a `.saved` replaced by `.editing`
    /// over an empty field is exactly what makes Save demote a working install (`isUsable`).
    @State private var reopened: [ProviderKind: String] = [:]

    private var canSave: Bool {
        model.openAIKeyState.isValid || model.anthropicKeyState.isValid
    }

    /// Whether a key row shows its field and Check. A saved key is one line, not a field: the
    /// field comes back only when the row is reopened for a new key. Everything else — empty,
    /// being typed, checked either way — shows it.
    static func showsKeyField(_ state: KeyFieldState, reopened: Bool) -> Bool {
        if case .saved = state { return reopened }
        return true
    }

    private func showsField(_ kind: ProviderKind) -> Bool {
        Self.showsKeyField(state(of: kind), reopened: reopened[kind] != nil)
    }

    /// The Save row has something to save only while a field is on show. With every key saved and
    /// every row collapsed it is a button that would write the file it just wrote.
    private var showsSaveRow: Bool { showsField(.openai) || showsField(.anthropic) }

    private var home: String { NSHomeDirectory() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                keysSection
                conversationSection
                backendSection
                voiceSection
                permissionsSection
                cursorSection
                supportSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Keys

    /// First, because on a fresh install it is the only section that does anything: everything else
    /// describes a Saathi that cannot speak yet.
    private var keysSection: some View {
        section("KEYS") {
            keyRow(
                systemImage: "key.fill",
                title: "OpenAI",
                detail: "voice and thinking",
                text: $openAIKey,
                state: model.openAIKeyState,
                kind: .openai)
            keyRow(
                systemImage: "key",
                title: "Anthropic",
                detail: "looking at the screen",
                text: $anthropicKey,
                state: model.anthropicKeyState,
                kind: .anthropic)

            // The sentence under the fields is the save it promises: what Saathi will become if
            // these are saved, in one line, before anybody commits to it.
            if !model.planExplanation.isEmpty {
                noteRow(model.planExplanation, emphasised: true)
            }
            if !model.unusedKeyNote.isEmpty {
                noteRow(model.unusedKeyNote, emphasised: false)
            }

            if showsSaveRow {
                saveRow
            }
        }
    }

    private var saveRow: some View {
        HStack {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .frame(width: 18)
            Text("Save and use these")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(canSave ? .white : Color.white.opacity(0.45))
            Spacer()
            Button(action: { actions.onSaveKeys(openAIKey, anthropicKey) }) {
                Text("Save")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(canSave ? Color(PointerBuddyView.tint) : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: canSave)
            .disabled(!canSave)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Conversation

    /// The last exchange and the way to the whole log. Here rather than on Home because Home is
    /// OpenClicky's fixed layout at OpenClicky's fixed height; this is the tab that scrolls.
    private var conversationSection: some View {
        section("CONVERSATION") {
            settingRow(systemImage: "person.wave.2", title: "You said", value: model.lastYouSaid.isEmpty ? "—" : model.lastYouSaid)
            settingRow(systemImage: "bubble.left", title: "Saathi said", value: model.lastSaathiSaid.isEmpty ? "—" : model.lastSaathiSaid)
            actionRow(
                systemImage: "doc.plaintext",
                title: "Open conversation log",
                detail: "~/.saathi/conversation.log — every turn, every look, every error",
                action: actions.onOpenConversationLog)
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        section("BACKEND") {
            settingRow(systemImage: "server.rack", title: "Backend", value: model.backendTitle)
            settingRow(
                systemImage: "key.viewfinder",
                title: "Token",
                value: !model.usesBackend ? "not needed" : (model.isBackendConfigured ? "configured" : "missing"))
            actionRow(
                systemImage: "doc.text",
                title: "Open settings file",
                detail: ConfigurationStore.defaultPath().path.replacingOccurrences(of: home, with: "~"),
                action: actions.onRevealSettingsFile)
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        section("VOICE") {
            // The language row is a setting in the same sense the rest are: something Saathi would
            // otherwise guess, and guessed wrong loudly enough to be reported.
            pickerRow(systemImage: "character.bubble", title: "Language", detail: "what it answers in")
            settingRow(systemImage: "waveform", title: "Voice", value: model.voiceTitle.isEmpty ? "—" : model.voiceTitle)
            settingRow(systemImage: "arrow.left.arrow.right", title: "A turn", value: model.laneTitle)
            settingRow(systemImage: "brain", title: "Where it thinks", value: model.providerTitle)
            settingRow(systemImage: "lock.shield", title: "Your voice", value: model.privacyLine)
            settingRow(systemImage: "keyboard", title: "Talk shortcut", value: "hold ⌃ control + ⌥ option")
        }
    }

    // MARK: - Permissions

    /// macOS's answer about what Saathi may do, and a way to ask again. On Home until the panel
    /// became OpenClicky's, which has no room for it — and this is where it belonged anyway.
    private var permissionsSection: some View {
        section("PERMISSIONS") {
            ForEach(Permission.allCases, id: \.title) { permission in
                permissionRow(permission)
            }
            if model.needsRestart {
                actionRow(
                    systemImage: "arrow.clockwise",
                    title: "Restart Saathi",
                    detail: "The grant needs a fresh start to take effect",
                    action: actions.onRestart)
            }
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        HStack {
            Image(systemName: permission.symbolName)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .frame(width: 18)
            Text(permission.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            if model.permissions[permission] == .granted {
                Text("granted")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button(action: { actions.onFixPermission(permission) }) {
                    Text("Fix")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(PointerBuddyView.tint)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        section("CURSOR") {
            toggleRow(
                systemImage: "arrow.up.to.line.compact",
                title: "Dock cursor in the island",
                detail: "The companion lives up here instead of on the desktop",
                isOn: Binding(get: { model.isCursorDocked }, set: { _ in actions.onToggleCursorDock() }))
            toggleRow(
                systemImage: "cursorarrow",
                title: "Show companion",
                detail: "Hide it and the island is the only place Saathi appears",
                isOn: Binding(get: { model.companionVisible }, set: { _ in actions.onToggleCompanion() }))
        }
    }

    // MARK: - Support

    private var supportSection: some View {
        section("SUPPORT") {
            actionRow(systemImage: "ladybug", title: "Report a bug", detail: "Opens the project's issue tracker") {
                if let url = URL(string: "https://github.com/saathihq/saathi/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            actionRow(systemImage: "power", title: "Quit Saathi", detail: nil, action: actions.onQuit)
        }
    }

    // MARK: - The row idiom, ported from NotchSettingsView

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.45))
            VStack(spacing: 1) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func settingRow(systemImage: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            Spacer()
            Text(value).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toggleRow(systemImage: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(DS.Colors.accent).scaleEffect(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func actionRow(systemImage: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// The language picker, wearing the row idiom so it does not read as a stray control.
    private func pickerRow(systemImage: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
            }
            Spacer()
            Picker("", selection: Binding(get: { model.language }, set: { actions.onLanguage($0) })) {
                ForEach(IslandLanguage.all) { language in
                    Text(language.title).tag(language.tag)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// A key, as a row: the same icon-and-title as every other. While a key is being entered the
    /// field and its Check sit where a value would be, with the verdict on the line below; once it
    /// is saved the row is one line — the masked key and a Change — because a field for a key that
    /// is already on disk is a field nobody should type into by accident.
    @ViewBuilder
    private func keyRow(
        systemImage: String,
        title: String,
        detail: String,
        text: Binding<String>,
        state: KeyFieldState,
        kind: ProviderKind
    ) -> some View {
        if case let .saved(masked) = state, !Self.showsKeyField(state, reopened: reopened[kind] != nil) {
            HStack {
                keyRowTitle(systemImage: systemImage, title: title, detail: detail)
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
                Text(masked)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.72))
                smallButton("Change") { reopened[kind] = masked }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    keyRowTitle(systemImage: systemImage, title: title, detail: detail)
                    Spacer(minLength: 8)

                    // SecureField so a key is not on screen while it is typed, and not in a screenshot.
                    SecureField("sk-…", text: text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 150)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                        .onChange(of: text.wrappedValue) { value in
                            // Typing invalidates an earlier verdict: a green tick next to a key that
                            // has since been edited is the panel lying about what it checked. A field
                            // emptied by Keep under a `.saved` verdict is not typing, and the verdict
                            // it would overwrite is the one Keep just put back.
                            if value.isEmpty, case .saved = self.state(of: kind) { return }
                            // A reopened field typed into and then emptied by hand is the same
                            // abandoned edit as Keep: Save would use the stored key, so the stored
                            // key's verdict is the one that must stand.
                            if value.isEmpty, let masked = reopened[kind] {
                                setState(kind, .saved(masked: masked))
                                return
                            }
                            setState(kind, .editing)
                        }

                    smallButton(state.isBusy ? "…" : "Check", enabled: !state.isBusy) {
                        actions.onCheckKey(kind, openAIKey, anthropicKey)
                    }
                    if let masked = reopened[kind] {
                        // Back to the saved key, whatever was typed: the field is cleared and the
                        // verdict it had is restored, so Save cannot mistake an abandoned edit for
                        // a missing key.
                        smallButton("Keep") {
                            text.wrappedValue = ""
                            setState(kind, .saved(masked: masked))
                            reopened[kind] = nil
                        }
                    }
                }
                verdict(for: state)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func keyRowTitle(systemImage: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
            }
        }
    }

    /// The small capsule the key rows use for Check, Change and Keep — one look for the three.
    private func smallButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: enabled)
        .disabled(!enabled)
    }

    private func state(of kind: ProviderKind) -> KeyFieldState {
        switch kind {
        case .openai: return model.openAIKeyState
        case .anthropic: return model.anthropicKeyState
        default: return .empty
        }
    }

    private func noteRow(_ text: String, emphasised: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: emphasised ? "arrow.turn.down.right" : "info.circle")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .frame(width: 18)
            // This sentence tells someone where their voice is about to go. It was 10.5pt at 65%
            // white, which on a dark panel is below the 4.5:1 contrast most people need to read
            // comfortably — a promise nobody can read is not a promise.
            Text(text)
                .font(.system(size: emphasised ? 12 : 11))
                .foregroundColor(Color.white.opacity(emphasised ? 0.92 : 0.7))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func setState(_ kind: ProviderKind, _ state: KeyFieldState) {
        switch kind {
        case .openai: model.openAIKeyState = state
        case .anthropic: model.anthropicKeyState = state
        default: break
        }
    }

    @ViewBuilder
    private func verdict(for state: KeyFieldState) -> some View {
        switch state {
        case .empty, .editing, .checking:
            EmptyView()
        case let .checked(check):
            switch check {
            case .valid:
                Text("✓ that key works")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.success)
                    .padding(.leading, 26)
            case let .rejected(message):
                Text(message)
                    .font(.system(size: 11)).foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            case let .unreachable(message):
                // Deliberately not red. Being offline is not the same as being wrong, and colouring
                // it like a failure sends people off to make a new key.
                Text(message)
                    .font(.system(size: 11)).foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.32))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        case let .saved(masked):
            Text("saved · \(masked)")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.72))
                .padding(.leading, 26)
        }
    }
}
