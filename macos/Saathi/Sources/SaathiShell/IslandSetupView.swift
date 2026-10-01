//
//  IslandSetupView.swift
//  SaathiShell
//
//  The island's Settings tab, behind the gear — OpenClicky's `NotchSettingsView`, ported: a scroll
//  of titled sections, each a rounded card of rows, with one row idiom (icon, title, value) and
//  three variants of it (a switch, a tappable row with a chevron, a key field).
//
//  The keys are rows here rather than a screen of their own. They were a panel with two big
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
    @State private var keys = VendorKeys()
    /// Save is the only button: it checks whatever was typed and saves it if the vendor accepts it.
    /// Not while a check is in flight — its verdict is about to decide.
    private func canSave(_ kind: ProviderKind) -> Bool {
        !model.keyStates[kind].isBusy && !keys[kind].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
        // The fields are view-local and start empty every time this is built — the island
        // collapsing tears it down — so a "works" left over from before is about a key no longer
        // in any field.
        .onAppear { actions.onKeyFields(keys, nil) }
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
                text: $keys.openAI,
                kind: .openai)
            keyRow(
                systemImage: "globe.asia.australia",
                title: "Sarvam",
                detail: "Indian languages, heard and spoken",
                text: $keys.sarvam,
                kind: .sarvam)
            keyRow(
                systemImage: "key",
                title: "Anthropic",
                detail: "looking at the screen",
                text: $keys.anthropic,
                kind: .anthropic)

            // The sentence under the fields is the save it promises: what Saathi will become if
            // these are saved, in one line, before anybody commits to it.
            if !model.planExplanation.isEmpty {
                noteRow(model.planExplanation, emphasised: true)
            }
            if !model.keysNote.isEmpty {
                noteRow(model.keysNote, emphasised: false)
            }

        }
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
            pickerRow(
                systemImage: "character.bubble",
                title: "Language",
                detail: model.sarvamSpeechOn ? "what it hears and answers in" : "what it answers in",
                selection: Binding(get: { model.language }, set: { actions.onLanguage($0) }),
                options: IslandLanguage.all.map { ($0.tag, $0.title) })
            // Only where it could be switched: a Sarvam key is saved, and a turn is three steps.
            // The detail is the whole of what turning it on means.
            if model.sarvamSpeechAvailable {
                toggleRow(
                    systemImage: "ear",
                    title: "Hear and speak through Sarvam",
                    detail: "Your voice, and what is said back, go to Sarvam",
                    isOn: Binding(get: { model.sarvamSpeechOn }, set: { actions.onSarvamSpeech($0) }))
            }
            settingRow(systemImage: "waveform", title: "Voice", value: model.voiceTitle.isEmpty ? "—" : model.voiceTitle)
            settingRow(systemImage: "arrow.left.arrow.right", title: "A turn", value: model.laneTitle)
            // A picker once there is more than one place it could think; a line of text until then.
            if model.providerChoices.count > 1 {
                pickerRow(
                    systemImage: "brain",
                    title: "Where it thinks",
                    detail: model.providerTitle,
                    selection: Binding(get: { model.provider }, set: { actions.onChooseProvider($0) }),
                    options: model.providerChoices.map { ($0.kind, $0.title) })
            } else {
                settingRow(systemImage: "brain", title: "Where it thinks", value: model.providerTitle)
            }
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

    /// A picker, wearing the row idiom so it does not read as a stray control.
    private func pickerRow<Tag: Hashable>(
        systemImage: String,
        title: String,
        detail: String,
        selection: Binding<Tag>,
        options: [(tag: Tag, title: String)]
    ) -> some View {
        HStack {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
            }
            Spacer()
            Picker("", selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].tag)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// A key, as a row: the same icon-and-title as every other, then a field and one Save. Pasting
    /// a key and pressing Save — or Return — is the whole job: Save checks the key with the vendor
    /// and writes it only if it is accepted. It used to be Check, then a Save row, then its Save
    /// capsule, and a row reopened with Change before any of that; three clicks is two too many to
    /// replace a key, and the disabled states in between read as "saved" when nothing was.
    /// A saved key is shown as the field's placeholder, so replacing it needs no Change either.
    private func keyRow(
        systemImage: String,
        title: String,
        detail: String,
        text: Binding<String>,
        kind: ProviderKind
    ) -> some View {
        let state = model.keyStates[kind]
        let save = {
            guard canSave(kind) else { return }
            actions.onSaveKeys(keys)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                keyRowTitle(systemImage: systemImage, title: title, detail: detail)
                Spacer(minLength: 8)

                // SecureField so a key is not on screen while it is typed, and not in a screenshot.
                SecureField(Self.placeholder(for: state), text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 150)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                    .onSubmit(save)
                    .onChange(of: text.wrappedValue) { _ in
                        // Every change is reported, with every field: typing invalidates an earlier
                        // verdict, emptying a field puts back the one the key on disk earns, and
                        // either changes what the sentence below has to say.
                        actions.onKeyFields(keys, kind)
                    }

                Button(action: save) {
                    Text(state.isBusy ? "…" : "Save")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(canSave(kind) ? Color(PointerBuddyView.tint) : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canSave(kind))
                .disabled(!canSave(kind))
            }
            verdict(for: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// What an empty field shows: the key on disk, masked, when there is one.
    static func placeholder(for state: KeyFieldState) -> String {
        if case let .saved(masked) = state { return "\(masked) — paste to replace" }
        return "paste a key"
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
