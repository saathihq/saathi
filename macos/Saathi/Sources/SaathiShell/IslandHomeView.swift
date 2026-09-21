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

    /// OpenClicky's exact numbers, and — more to the point — its exact structure.
    ///
    /// The backdrop and the content are siblings in one `ZStack` under one `.animation`, so the
    /// black shape growing and the text arriving are the same movement. Animating the shape on an
    /// AppKit layer instead, as this did, means SwiftUI knows nothing about the change: the content
    /// snaps to its final place while the black is still on its way, and the open reads as two
    /// things happening near each other rather than one thing opening.
    /// Driven from `NotchPanel.apply` with an explicit `withAnimation` rather than an
    /// `.animation(value:)` modifier. Explicit because the panel has to be able to make the change
    /// *without* animating — a test that asserts the mascot left the window cannot wait out a
    /// spring, and a tree change that only lands when a transition finishes is untestable.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// How far the top corners curve outward into the menu bar. OpenClicky measured ~6pt off
    /// HeyClicky; the island is drawn `flare` wider on each side so the body keeps its stated width.
    static let topCornerFlare: CGFloat = 6
    /// OpenClicky's two transitions: the compact strip scales from 0.92, the full panel from 0.96 —
    /// a bigger panel travelling the same visual distance needs a smaller scale delta or it reads
    /// as a lurch.
    static let compactTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.92, anchor: .top))
    static let openTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top))

    var body: some View {
        ZStack(alignment: .top) {
            // Nothing is drawn while collapsed on a display with no notch: there is no notch to be,
            // and a black rectangle over the menu bar would just be in the way. The handle marks it.
            if display.state != .collapsed || display.hasHardwareNotch {
                NotchIslandShape(
                    bottomCornerRadius: display.islandCornerRadius,
                    topCornerFlare: Self.topCornerFlare
                )
                .fill(Color.black)
                .frame(
                    width: display.islandSize.width + Self.topCornerFlare * 2,
                    height: display.islandSize.height)
            }

            // Only the live layer is in the tree: a hidden sibling at a fixed frame would inflate
            // the fitting size, and it would keep the mascot in the window with its ticker running.
            switch display.state {
            case .collapsed:
                Color.clear.frame(width: 1, height: 1)
            case .compact:
                IslandCompactView(display: display, model: model, mascot: mascot)
                    .frame(width: display.compactSize.width, height: display.compactSize.height)
                    .transition(Self.compactTransition)
            case .open:
                IslandHomeView(display: display, model: model, mascot: mascot, actions: actions)
                    .frame(width: display.openSize.width, height: display.openSize.height)
                    .transition(Self.openTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Clipped to the island itself, so the content is revealed and concealed by the shape as it
        // springs rather than merely fading on top of it.
        //
        // Without this the two come apart in the middle of the movement: a closing island shrinks
        // its black down to the notch while the panel's text is still laid out at full size, so for
        // a few frames the words sit on the wallpaper outside the island. Masking makes it behave
        // like one solid object opening and closing — which is what reads as polished, rather more
        // than the spring constants do.
        .mask(alignment: .top) {
            NotchIslandShape(
                bottomCornerRadius: display.islandCornerRadius,
                topCornerFlare: Self.topCornerFlare
            )
            .frame(
                width: display.islandSize.width + Self.topCornerFlare * 2,
                height: display.islandSize.height)
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

/// OpenClicky's `NotchFullPanelView` and `NotchHomeView`, ported rather than reinterpreted.
///
/// The previous version of this file kept OpenClicky's geometry and wrote its own contents — a
/// "Where I think" column, a permissions list, three capsule buttons. It was the same island with a
/// different panel inside it, which is not what "the same panel" means. This is the panel: the tab
/// bar in the menu-bar band, "Add skills" over a row of skill tiles on the left, ⌘ Shortcuts on the
/// right, "Active integrations" and Dock Cursor along the bottom. 512 × 232 including the band.
struct IslandHomeView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let mascot: MascotView
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 0) {
            // The tab bar lives in the menu-bar band, on either side of the physical notch.
            IslandTabBar(display: display, model: model, actions: actions)
                .frame(height: 24)
                .padding(.horizontal, 14)
                .padding(.top, 5)
                .frame(height: display.topBandHeight, alignment: .top)

            Group {
                switch model.tab {
                case .home: homeBody
                case .agents: IslandAgentsView(model: model)
                case .setup: IslandSetupView(display: display, model: model, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
        }
    }

    // MARK: - Home

    private var homeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add skills")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(.white)
                    Text("Skills give Saathi superpowers")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.white.opacity(0.55))
                    SkillTilesRow(store: model.skills, onComposingChanged: { model.isComposingSkill = $0 })
                        .padding(.top, 9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "command").font(.system(size: 10, weight: .semibold))
                        Text("Shortcuts").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(Color.white.opacity(0.75))
                    .padding(.top, 1)
                    // The four shortcuts, in OpenClicky's order. Talk is the one Saathi recognises
                    // today; the other three land with the shortcut recogniser.
                    shortcutRow(title: "Talk", keys: ["⌃ control", "⌥ option"])
                    shortcutRow(title: "Text", keys: ["⌃ control", "2×"])
                    shortcutRow(title: "Dictate", keys: ["fn", "⌃ control"])
                    shortcutRow(title: model.isAlwaysListening ? "Hands-free ●" : "Hands-free", keys: ["fn", "⌃ control", "2×"])
                }
                .frame(width: 180, alignment: .leading)
            }

            Spacer(minLength: 6)

            Text("Active integrations")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.75))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(model.integrations) { integration in
                        integrationIcon(integration)
                    }
                    Button(action: actions.onRevealSettingsFile) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Configure an integration in ~/.saathi/shell.json")
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "#161616")))

                Button(action: actions.onToggleCursorDock) {
                    Text(model.isCursorDocked ? "Release Cursor" : "Dock Cursor")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: "#262626")))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(model.state != .idle)

                // (i): Saathi says what it does, next to the companion. The panel closes first so
                // the companion is actually in view when it starts talking.
                Button(action: actions.onExplain) {
                    Image(systemName: "info")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(hex: "#262626")))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("What does Saathi do?")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func integrationIcon(_ integration: IslandIntegration) -> some View {
        Image(systemName: integration.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(integration.isOn ? .white : Color.white.opacity(0.35))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(integration.isOn ? Color(hex: integration.tintHex) : Color.white.opacity(0.08))
            )
            .help(integration.isOn ? "\(integration.title) connected" : "\(integration.title) not configured")
    }

    private func shortcutRow(title: String, keys: [String]) -> some View {
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
    }
}

// MARK: - Tab bar

/// OpenClicky's `NotchTabBar`: two pills on the left, the backend status pill and the gear on the
/// right. Settings is behind the gear in both, which is why the visible bar reads Home · Agents.
struct IslandTabBar: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    var body: some View {
        HStack(spacing: 8) {
            tabPill(title: "Home", systemImage: "house", tab: .home)
            tabPill(title: "Agents", systemImage: "sparkles", tab: .agents)

            // A hardware notch sits in the middle of this band; nothing may be laid out under it.
            Spacer(minLength: display.notchGap)

            backendStatusPill

            iconButton(systemImage: "gearshape.fill", help: "Setup") { model.tab = .setup }
                .background(
                    Circle().fill(model.tab == .setup ? Color.white.opacity(0.16) : Color.clear)
                )
        }
    }

    private func tabPill(title: String, systemImage: String, tab: IslandTab) -> some View {
        let isSelected = model.tab == tab
        return Button(action: { model.tab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : Color.white.opacity(0.65))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.white.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Where Saathi is connected, on the lane in use. Green with the host once the lane has what it
    /// needs; red with what is missing until then — and a tap on the red one goes to Setup, which
    /// is where the missing thing is entered, rather than to the file behind it.
    private var backendStatusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.isConnectionConfigured ? DS.Colors.success : DS.Colors.overlayCursorColor)
                .frame(width: 5, height: 5)
            Text(model.connectionTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(model.isConnectionConfigured ? Color.white.opacity(0.7) : .white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                model.isConnectionConfigured ? Color.white.opacity(0.08) : DS.Colors.overlayCursorColor.opacity(0.35)
            )
        )
        .onTapGesture {
            if model.isConnectionConfigured { actions.onRevealSettingsFile() } else { model.tab = .setup }
        }
        .pointerCursor()
    }

    private func iconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.75))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }
}
