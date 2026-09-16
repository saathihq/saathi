//
//  IslandHomeView.swift
//  SaathiShell
//
//  What the open island actually draws: OpenClicky's Home panel, with Saathi's content. One root
//  view switches on the panel's state (nothing / the busy strip / the full Home panel); the panel
//  hosts it once, in an `NSHostingView`, and reads the model and hands out the actions.
//

import AppKit
import SaathiKit
import SaathiMascot
import SwiftUI

/// The one `MascotView` the panel owns, wrapped so it can sit inside the SwiftUI layout. It must
/// never build its own `MascotView` — there is one face and one ticker, and the panel supplies it.
/// Removed from the SwiftUI tree (the compact and open cases are the only ones that mention it),
/// `dismantleNSView` takes it out of the window, which is what stops its display-link ticker.
struct MascotHostView: NSViewRepresentable {
    let mascot: MascotView

    func makeNSView(context: Context) -> MascotView { mascot }
    func updateNSView(_ nsView: MascotView, context: Context) {}
    static func dismantleNSView(_ nsView: MascotView, coordinator: ()) {
        nsView.removeFromSuperview()
    }
}

/// The bridge's state decides what the island's content is; collapsed draws nothing at all.
struct IslandRootView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let mascot: MascotView
    let actions: IslandActions

    var body: some View {
        switch display.state {
        case .collapsed:
            Color.clear
        case .compact:
            IslandCompactView(display: display, model: model, mascot: mascot)
        case .open:
            IslandHomeView(display: display, model: model, mascot: mascot, actions: actions)
        }
    }
}

/// The strip that opens by itself while Saathi is busy: the face and the word, centred in the
/// band below the notch.
struct IslandCompactView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let mascot: MascotView

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: display.notchHeight)
            HStack(spacing: 10) {
                MascotHostView(mascot: mascot).frame(width: 32, height: 32)
                Text(model.state.word)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The full island: who is talking (the top band), where it thinks and how to talk to it (the
/// body), what to fix (the permissions list), and the controls (the bottom row). Modelled on
/// OpenClicky's `NotchFullPanelView` / `NotchHomeView`.
struct IslandHomeView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let mascot: MascotView
    let actions: IslandActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBand
                .padding(.horizontal, 14)
                .frame(height: display.topBandHeight)
            VStack(alignment: .leading, spacing: 0) {
                tabStrip
                switch model.tab {
                case .home:
                    HStack(alignment: .top, spacing: 18) {
                        leftColumn
                        rightColumn
                    }
                case .setup:
                    IslandSetupView(display: display, model: model, actions: actions)
                }
                bottomRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: the two faces

    private var tabStrip: some View {
        HStack(spacing: 6) {
            tabButton("Home", .home)
            tabButton("Setup", .setup)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private func tabButton(_ title: String, _ tab: IslandTab) -> some View {
        Button(action: { model.tab = tab }) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(model.tab == tab ? .white : Color.white.opacity(0.45))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: top band — who is talking, split around the notch

    private var topBand: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Path(PointerBuddyView.trianglePath(side: 10))
                    .fill(Color(PointerBuddyView.tint))
                    .frame(width: 10, height: 10)
                Text("Saathi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer(minLength: display.notchGap)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.state.word)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
            }
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .idle, .asleep: return .green
        case .alert: return .red
        default: return Color(PointerBuddyView.tint)
        }
    }

    // MARK: left column — where it thinks

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            MascotHostView(mascot: mascot).frame(width: 72, height: 72)
            Text("Where I think")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 4)
            Text(model.providerTitle)
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.55))
            Text(model.privacyLine)
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.55))
            capsuleButton("Provider…", action: actions.onProvider)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: right column — how to talk to it, and what to fix

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("command", "Shortcuts")
            shortcutRow(title: "Talk", keys: ["⌃ control", "⌥ option"], note: "hold")
            shortcutRow(title: "Talk from the menu", keys: ["menu bar ▸ Talk"])
            sectionHeader("checkmark.shield", "Permissions")
                .padding(.top, 4)
            ForEach(Permission.allCases, id: \.title) { permission in
                permissionRow(permission)
            }
            if model.needsRestart {
                Button(action: actions.onRestart) {
                    Text("Restart Saathi")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                Text("The grant needs a fresh start to take effect.")
                    .font(.system(size: 8.5))
                    .foregroundColor(Color.white.opacity(0.45))
            }
        }
        .frame(width: 180, alignment: .leading)
    }

    private func sectionHeader(_ systemImage: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundColor(Color.white.opacity(0.75))
    }

    private func shortcutRow(title: String, keys: [String], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.system(size: 10.5)).foregroundColor(Color.white.opacity(0.85))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.8))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.12)))
                    }
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        HStack {
            Text(permission.title).font(.system(size: 10.5)).foregroundColor(Color.white.opacity(0.85))
            Spacer()
            if model.permissions[permission] == .granted {
                Text("✓").font(.system(size: 10.5, weight: .semibold)).foregroundColor(.green)
            } else {
                Button(action: { actions.onFixPermission(permission) }) {
                    Text("Fix")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(PointerBuddyView.tint)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: bottom row — the controls

    private var bottomRow: some View {
        HStack(spacing: 8) {
            capsuleButton(model.state == .listening ? "Stop talking" : "Talk", action: actions.onTalk)
            capsuleButton(model.companionVisible ? "Companion on" : "Companion off", action: actions.onToggleCompanion)
            Spacer()
            capsuleButton("Quit", action: actions.onQuit)
        }
        .padding(.top, 6)
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)))
        }
        .buttonStyle(.plain)
    }
}
