//
//  IslandStyle.swift
//  SaathiShell
//
//  The handful of things OpenClicky's `DesignSystem.swift` provides that the island's panels use.
//  Ported rather than re-derived: the panel is being matched to the pixel, and a hex literal typed
//  out again by hand is exactly the kind of thing that ends up one digit off.
//
//  Only what the panels actually reference is here. The rest of OpenClicky's design system is a
//  full component library for a settings window Saathi does not have.
//

import AppKit
import SwiftUI

/// OpenClicky's `DS.Colors`, narrowed to the names the island uses.
enum DS {
    enum Colors {
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        /// What a switch is tinted when it is on.
        static let accent = blue600
        /// An independent green, so a success state is not mistaken for the accent.
        static let success = Color(hex: "#34D399")
        /// The cursor's own red. On the island it marks the one thing that is not set up yet.
        static let overlayCursorColor = Color(hex: "#F0452B")
    }
}

extension Color {
    /// A Color from "#FF5733" or "FF5733".
    init(hex: String) {
        let sanitised = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        Scanner(string: sanitised).scanHexInt64(&value)

        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }
}

/// Shows the pointing-hand cursor over a control.
///
/// Through AppKit's cursor-rect system rather than `NSCursor.push()` in `.onHover`: cursor rects
/// are resolved by the window, so they neither fight SwiftUI's own cursor handling nor leave the
/// cursor stack unbalanced when the pointer crosses several controls quickly — which on an island
/// that opens under the pointer is the normal case, not the edge case.
private final class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Transparent to hit testing, so the control underneath still gets the click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PointerCursorNSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // A resize changes the rect the cursor applies to; AppKit only recalculates when asked.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

extension View {
    /// The pointing-hand treatment shared by every interactive control on the island. A disabled
    /// control opts out and keeps the arrow.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        overlay {
            if isEnabled { PointerCursorView() }
        }
    }
}
