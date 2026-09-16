//
//  IslandSetupView.swift
//  SaathiShell
//
//  The island's second face: two keys, a check each, and one sentence saying what Saathi became.
//
//  The view holds the text being typed and nothing else. Validation, the plan and the file all live
//  behind the actions, so this file can be looked at and changed without touching anything that can
//  leak a key.
//

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

    private var canSave: Bool {
        model.openAIKeyState.isValid || model.anthropicKeyState.isValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Give me a key and I will set myself up")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(.white)

            keyField(
                title: "OpenAI",
                note: "voice and thinking",
                text: $openAIKey,
                state: model.openAIKeyState,
                kind: .openai)

            keyField(
                title: "Anthropic",
                note: "saved for later — nothing uses it yet",
                text: $anthropicKey,
                state: model.anthropicKeyState,
                kind: .anthropic)

            // The language row sits with the keys because it is the same kind of decision: something
            // Saathi would otherwise guess, and guessed wrong loudly enough to be reported.
            HStack(spacing: 8) {
                Text("Language")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Picker("", selection: Binding(
                    get: { model.language },
                    set: { actions.onLanguage($0) }
                )) {
                    ForEach(IslandLanguage.all) { language in
                        Text(language.title).tag(language.tag)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
                Text("what it answers in")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.62))
                Spacer()
            }

            if !model.planExplanation.isEmpty {
                // This sentence tells someone where their voice is about to go. It was 10.5pt at
                // 65% white, which on a dark panel is below the 4.5:1 contrast most people need to
                // read comfortably — a promise nobody can read is not a promise.
                Text(model.planExplanation)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }

            if !model.unusedKeyNote.isEmpty {
                Text(model.unusedKeyNote)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: { actions.onSaveKeys(openAIKey, anthropicKey) }) {
                    Text("Save and use these")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(canSave
                            ? Color(PointerBuddyView.tint)
                            : Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyField(
        title: String,
        note: String,
        text: Binding<String>,
        state: KeyFieldState,
        kind: ProviderKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.62))
            }
            HStack(spacing: 6) {
                // SecureField so a key is not on screen while it is typed, and not in a screenshot.
                SecureField("sk-…", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
                    .onChange(of: text.wrappedValue) { _ in
                        // Typing invalidates an earlier verdict: a green tick next to a key that has
                        // since been edited is the panel lying about what it checked.
                        setState(kind, .editing)
                    }

                Button(action: { actions.onCheckKey(kind, openAIKey, anthropicKey) }) {
                    Text(state.isBusy ? "Checking…" : "Check")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
            }
            verdict(for: state)
        }
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
                    .font(.system(size: 11)).foregroundColor(.green)
            case let .rejected(message):
                Text(message)
                    .font(.system(size: 11)).foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                    .fixedSize(horizontal: false, vertical: true)
            case let .unreachable(message):
                // Deliberately not red. Being offline is not the same as being wrong, and colouring
                // it like a failure sends people off to make a new key.
                Text(message)
                    .font(.system(size: 11)).foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.32))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .saved(masked):
            Text("saved · \(masked)")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.72))
        }
    }
}
