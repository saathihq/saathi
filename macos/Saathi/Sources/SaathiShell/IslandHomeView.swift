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

/// The full island: who is talking (the top band), where it thinks and how to talk to it (the
/// body), what to fix (the permissions list), and the controls (the bottom row). Modelled on
/// OpenClicky's `NotchFullPanelView` / `NotchHomeView`.
struct IslandHomeView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let mascot: MascotView
    let actions: IslandActions

    /// OpenClicky's `NotchFullPanelView`, structurally: the tab bar lives *in* the menu-bar band on
    /// either side of the physical notch, and the panel's content begins six points below it.
    ///
    /// Saathi used to stack a title band and then a tab strip under it — two bands where OpenClicky
    /// has one — which is most of why the island was taller than its content and had a strip of dead
    /// space across the top. The status dot keeps its place on the right of the notch, where the
    /// band is otherwise empty.
    var body: some View {
        VStack(spacing: 0) {
            topBand
                .frame(height: 24)
                .padding(.horizontal, 14)
                .padding(.top, 5)
                .frame(height: display.topBandHeight, alignment: .top)

            Group {
                switch model.tab {
                case .home: homeBody
                case .setup: IslandSetupView(display: display, model: model, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
            // OpenClicky's NotchHomeView padding, applied to whichever face is showing rather than
            // to Home alone — the Setup tab was running its text into the island's left edge.
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    // MARK: the band — tabs to the left of the notch, state to the right

    private var topBand: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                tabButton("Home", .home)
                tabButton("Setup", .setup)
            }
            Spacer(minLength: display.notchGap)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.state.word)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    private func tabButton(_ title: String, _ tab: IslandTab) -> some View {
        Button(action: { model.tab = tab }) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(model.tab == tab ? .white : Color.white.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: the Home tab — OpenClicky's NotchHomeView, with Saathi's content

    private var homeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                leftColumn
                rightColumn
            }
            Spacer(minLength: 6)
            bottomRow
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

    /// OpenClicky's left column exactly: a bold title, a dim subtitle, then a row of tiles nine
    /// points below. Saathi's tile row is the face and what the choice means for the learner's
    /// voice, which is the thing worth looking at on this panel.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Where I think")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(.white)
            Text(model.providerTitle)
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.55))
            HStack(spacing: 10) {
                MascotHostView(mascot: mascot).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.privacyLine)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    capsuleButton("Provider…", action: actions.onProvider)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: right column — how to talk to it, and what to fix

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("command", "Shortcuts")
            shortcutRow(title: "Talk", keys: ["⌃ control", "⌥ option"], note: "hold")
            // Short enough to sit in OpenClicky's 180pt column without eliding. The long form
            // ("Talk from the menu" / "menu bar ▸ Talk") truncated to an ellipsis at this width,
            // which tells a reader less than the short form does.
            shortcutRow(title: "From the menu", keys: ["Talk"])
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
        .padding(.top, 8)
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
