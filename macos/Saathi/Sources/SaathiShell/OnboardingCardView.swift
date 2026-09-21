//
//  OnboardingCardView.swift
//  SaathiShell
//
//  First run's card: one dark, rounded, centred panel whose contents follow `OnboardingModel.step`.
//
//  The shape is HeyClicky's first launch, which is the reference this was asked to match — a quiet
//  translucent card over whatever is on screen, a title and one sentence under it, the character in
//  the middle, one pale pill of a button; and for the demo, step dots along the top, "Skip demo" in
//  the corner, a speech bubble, and "Or type here" beside the state.
//
//  It decides nothing. Titles and sentences come from `OnboardingScript`, what is enabled comes
//  from the model, and every control calls one coordinator method. Everything shown is also spoken
//  by the coordinator, so nothing here may carry information the script does not.
//

import AppKit
import SaathiContract
import SaathiKit
import SaathiMascot
import SwiftUI

/// The numbers, in one place, so the look can be argued with in one place.
enum OnboardingStyle {
    static let cardSize = CGSize(width: 560, height: 440)
    static let cornerRadius: CGFloat = 24
    static let titleFont = Font.system(size: 21, weight: .semibold)
    static let bodyFont = Font.system(size: 13.5)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.09)
    static let pillTop = Color(hex: "#E4ECFF")
    static let pillBottom = Color(hex: "#A9C0FF")
    static let pillText = Color(hex: "#0B1020")
    static let bubble = Color(hex: "#F3D2B0")
    static let bubbleText = Color(hex: "#3A2A1C")
}

/// The card's own `MascotView`, hosted. Separate from the island's: that one is the island's to
/// add and remove, and this one lives exactly as long as the card.
struct OnboardingMascot: NSViewRepresentable {
    let mascot: MascotView
    func makeNSView(context: Context) -> MascotView { mascot }
    func updateNSView(_ nsView: MascotView, context: Context) {}
}

struct OnboardingCardView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let mascot: MascotView?
    /// Palette name → hex, in `mascot.json`'s order.
    let palette: [(name: String, hex: String)]
    /// Supported language tags with the name to show for each.
    let languages: [(tag: String, name: String)]
    @Binding var startAtLogin: Bool

    @State private var typed = ""

    private var model: OnboardingModel { coordinator.model }
    private var line: OnboardingLine { OnboardingScript.line(for: model) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 8)
            content
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .frame(width: OnboardingStyle.cardSize.width, height: OnboardingStyle.cardSize.height)
        .background(
            RoundedRectangle(cornerRadius: OnboardingStyle.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingStyle.cornerRadius, style: .continuous)
                .strokeBorder(OnboardingStyle.hairline, lineWidth: 1)
        )
        .onChange(of: model.step) { _ in typed = "" }
    }

    // MARK: - Top bar

    private var demoIndex: Int? {
        guard case let .demo(demo) = model.step else { return nil }
        switch demo {
        case .micCheck: return 0
        case .holdToTalk: return 1
        case .question: return 2
        case .trialChat: return 3
        case .providerChoice: return 4
        }
    }

    private var topBar: some View {
        ZStack {
            if let demoIndex {
                HStack(spacing: 9) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(index == demoIndex ? OnboardingStyle.pillBottom
                                  : index < demoIndex ? OnboardingStyle.pillBottom.opacity(0.75) : Color.white.opacity(0.16))
                            .frame(width: index == demoIndex ? 22 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(demoIndex + 1) of 5")
                HStack {
                    Spacer()
                    Button("Skip demo") { coordinator.skipDemo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(OnboardingStyle.dim)
                        .pointerCursor()
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .colour: colour
        case .intoNotch: simple(symbol: "arrow.up.to.line")
        case let .permission(permission): permissionCard(permission)
        case .allSet: allSet
        case .demo(.micCheck): listening(showKeys: false)
        case .demo(.holdToTalk): listening(showKeys: true)
        case let .demo(.question(question)): questionCard(question)
        case .demo(.trialChat): trialCard
        case .demo(.providerChoice): providerCard
        case .finished: simple(symbol: "checkmark")
        }
    }

    private func heading(_ subtitle: String? = nil) -> some View {
        VStack(spacing: 8) {
            Text(line.title)
                .font(OnboardingStyle.titleFont)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(subtitle ?? Self.subtitle(for: line))
                .font(OnboardingStyle.bodyFont)
                .foregroundColor(OnboardingStyle.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What goes under the title: the spoken line, without the title it opens with. Saathi says
    /// "Can I hear you? Say anything…" as one breath, but a card that prints its heading twice
    /// reads as a mistake. A line that *is* its title (the questions) leaves the way to answer.
    static func subtitle(for line: OnboardingLine) -> String {
        let bare = { (text: String) in text.trimmingCharacters(in: CharacterSet(charactersIn: " .?!:,")) }
        let title = bare(line.title)
        guard !title.isEmpty, line.spoken.lowercased().hasPrefix(title.lowercased()) else { return line.spoken }
        let rest = bare(String(line.spoken.dropFirst(title.count)))
        guard !rest.isEmpty else { return "Say it, or type it." }
        let tail = String(line.spoken.dropFirst(title.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?!:,"))
        let ending = line.spoken.last.map { ".?!".contains($0) ? String($0) : "" } ?? ""
        return tail.prefix(1).uppercased() + tail.dropFirst() + ending
    }

    private func face(_ size: CGFloat) -> some View {
        Group {
            if let mascot {
                OnboardingMascot(mascot: mascot)
            } else {
                Circle().fill(OnboardingStyle.pillBottom.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            heading()
            face(96)
            Toggle(isOn: $startAtLogin) {
                Text(OnboardingScript.startAtLoginNote)
                    .font(.system(size: 12))
                    .foregroundColor(OnboardingStyle.faint)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.Colors.accent)
        }
    }

    private var colour: some View {
        VStack(spacing: 22) {
            heading()
            face(96)
            HStack(spacing: 14) {
                ForEach(palette, id: \.name) { entry in
                    Button { coordinator.choose(colour: entry.name) } label: {
                        Circle()
                            .fill(Color(hex: entry.hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                                    .padding(-4)
                                    .opacity((model.colour ?? OnboardingModel.defaultColour) == entry.name ? 1 : 0)
                            )
                            .shadow(color: Color(hex: entry.hex).opacity(0.55), radius: 6)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel(entry.name)
                }
            }
        }
    }

    private func simple(symbol: String) -> some View {
        VStack(spacing: 24) {
            heading()
            face(96)
        }
    }

    private func permissionCard(_ permission: Permission) -> some View {
        let order = OnboardingModel.permissionOrder
        let position = (order.firstIndex(of: permission) ?? 0) + 1
        return VStack(spacing: 20) {
            Text("\(position) of \(order.count)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(OnboardingStyle.faint)
            Image(systemName: permission.symbolName)
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(OnboardingStyle.pillBottom)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .accessibilityHidden(true)
            heading(
                coordinator.waitingOnSettings == permission
                    ? "\(permission.reason) \(OnboardingScript.inputMonitoringHelper)"
                    : nil)
        }
    }

    private var allSet: some View {
        VStack(spacing: 18) {
            heading()
            face(88)
            if !model.deniedPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.deniedPermissions, id: \.self) { permission in
                        Text(OnboardingScript.deniedNote(for: permission))
                            .font(.system(size: 11.5))
                            .foregroundColor(OnboardingStyle.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func speechBubble(_ text: String, placeholder: String) -> some View {
        Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 13.5))
            .foregroundColor(text.isEmpty ? OnboardingStyle.bubbleText.opacity(0.5) : OnboardingStyle.bubbleText)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingStyle.bubble))
    }

    private func listening(showKeys: Bool) -> some View {
        VStack(spacing: 22) {
            heading()
            HStack(alignment: .center, spacing: 14) {
                face(80)
                speechBubble(coordinator.bubble, placeholder: "What I hear shows up here.")
            }
            if showKeys {
                HStack(spacing: 8) {
                    keyCap("⌃", "control")
                    Text("+").foregroundColor(OnboardingStyle.faint)
                    keyCap("⌥", "option")
                }
                .opacity(model.heldKeys ? 1 : 0.7)
            }
        }
    }

    private func keyCap(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6) {
            Text(glyph).font(.system(size: 14, weight: .semibold))
            Text(name).font(.system(size: 12))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(model.heldKeys ? 0.22 : 0.08))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OnboardingStyle.hairline))
    }

    private func questionCard(_ question: OnboardingQuestion) -> some View {
        VStack(spacing: 18) {
            heading()
            HStack(alignment: .center, spacing: 14) {
                face(80)
                speechBubble(coordinator.bubble, placeholder: "Hold control and option, and tell me.")
            }
            switch question {
            case .manner:
                HStack(spacing: 8) {
                    ForEach(Manner.allCases, id: \.self) { manner in
                        chip(manner.title) { coordinator.answer(manner.title) }
                    }
                }
            case .language:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(languages, id: \.tag) { language in
                            chip(language.name) { coordinator.answer(language.tag) }
                        }
                    }
                }
            case .name, .firstGoal:
                EmptyView()
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(OnboardingStyle.hairline))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var trialCard: some View {
        VStack(spacing: 20) {
            heading()
            face(80)
        }
    }

    private var providerCard: some View {
        VStack(spacing: 14) {
            heading("This decides where your voice goes. You can change it later in Setup.")
            VStack(spacing: 8) {
                ForEach(model.availableProviderChoices, id: \.self) { choice in
                    Button { coordinator.choose(provider: choice) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(OnboardingScript.title(for: choice))
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                            Text(OnboardingScript.detail(for: choice))
                                .font(.system(size: 11.5))
                                .foregroundColor(OnboardingStyle.dim)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingStyle.hairline))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch model.step {
        case .welcome:
            primary("Let's start") { coordinator.next() }
        case .colour, .intoNotch:
            primary("Continue") { coordinator.next() }
        case let .permission(permission):
            if coordinator.waitingOnSettings == permission {
                HStack(spacing: 14) {
                    secondary("Skip for now") { coordinator.settlePermissionFromSettings() }
                    primary("I've turned it on") { coordinator.settlePermissionFromSettings() }
                }
            } else {
                primary("Allow", enabled: !coordinator.isBusy) { coordinator.requestCurrentPermission() }
            }
        case .allSet:
            primary("Meet Saathi") { coordinator.next() }
        case .demo(.micCheck), .demo(.holdToTalk):
            primary("Continue", enabled: model.canContinue) { coordinator.next() }
        case .demo(.question):
            HStack(spacing: 12) {
                statePill
                typeHere
            }
        case .demo(.trialChat):
            trialFooter
        case .demo(.providerChoice), .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trialFooter: some View {
        switch model.trial {
        case .notAsked:
            HStack(spacing: 14) {
                secondary("Skip this") { coordinator.skipTrial() }
                primary("Start the chat") { coordinator.startTrial() }
            }
        case .asking:
            primary("Setting up…", enabled: false) {}
        case .ready:
            primary("Continue") { coordinator.next() }
        case .failed:
            HStack(spacing: 14) {
                secondary("Skip this") { coordinator.skipTrial() }
                primary("Try again", enabled: !coordinator.isBusy) { coordinator.startTrial() }
            }
        }
    }

    private var statePill: some View {
        HStack(spacing: 8) {
            Image(systemName: coordinator.isSpeaking ? "waveform" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(coordinator.isSpeaking ? "Saathi is speaking…" : "Hold ⌃ ⌥ and answer")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(OnboardingStyle.pillText)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Capsule().fill(LinearGradient(
            colors: [OnboardingStyle.pillTop, OnboardingStyle.pillBottom], startPoint: .top, endPoint: .bottom)))
        .opacity(coordinator.isSpeaking ? 1 : 0.92)
        .accessibilityElement(children: .combine)
    }

    private var typeHere: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").font(.system(size: 12)).foregroundColor(OnboardingStyle.faint)
            TextField("Or type here", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .onSubmit {
                    let answer = typed
                    typed = ""
                    coordinator.answer(answer)
                }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(OnboardingStyle.hairline))
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(OnboardingStyle.pillText)
                .padding(.horizontal, 26)
                .frame(height: 38)
                .background(Capsule().fill(LinearGradient(
                    colors: [OnboardingStyle.pillTop, OnboardingStyle.pillBottom], startPoint: .top, endPoint: .bottom)))
                .shadow(color: OnboardingStyle.pillBottom.opacity(0.35), radius: 10, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .pointerCursor(isEnabled: enabled)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OnboardingStyle.dim)
                .padding(.horizontal, 14)
                .frame(height: 38)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
