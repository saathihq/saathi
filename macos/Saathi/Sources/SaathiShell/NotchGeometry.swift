//
//  NotchGeometry.swift
//  SaathiShell
//
//  Where the island hangs. On a notched screen the collapsed island is exactly the hardware notch,
//  so nothing at all shows until the pointer reaches the top of the screen. On a screen without a
//  notch we pretend there is one — 190 pt wide, as tall as the menu-bar band — and mark it with a
//  small handle, because there is no black hardware to hide behind. Pure: every input is a number,
//  so the whole layout can be checked without a display.
//

import CoreGraphics

public struct NotchGeometry: Equatable {

    public let screenFrame: CGRect
    public let hasHardwareNotch: Bool
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat

    /// The width of the notch we pretend a notch-less display has.
    public static let virtualNotchWidth: CGFloat = 190
    /// The capsule that marks where to reach on a display without a notch.
    public static let handleSize = CGSize(width: 44, height: 6)
    public static let handleTopInset: CGFloat = 3
    /// How far outside the island the pointer still counts as hovering. Tight while collapsed so
    /// the island does not open by accident, looser once open so a small overshoot does not close it.
    public static let hoverMarginCollapsed: CGFloat = 6
    public static let hoverMarginOpen: CGFloat = 14

    public init(screenFrame: CGRect, hasHardwareNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.hasHardwareNotch = hasHardwareNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    /// Exactly the notch (or the virtual one), hanging from the top edge, centred.
    public var notchRect: CGRect {
        CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// The 44 × 6 handle, centred where the notch would be and tucked `handleTopInset` below the
    /// screen's top edge — inside the menu-bar band, not under it.
    public var handleRect: CGRect {
        CGRect(
            x: screenFrame.midX - Self.handleSize.width / 2,
            y: screenFrame.maxY - Self.handleTopInset - Self.handleSize.height,
            width: Self.handleSize.width,
            height: Self.handleSize.height
        )
    }

    /// Whether there is anywhere to put the handle. A display with a hardware notch never needs
    /// one, and a display whose menu bar is hidden — or is in full screen — has no band to tuck it
    /// into, so a handle there would sit on top of somebody's content with nothing to explain it.
    public var showsHandle: Bool {
        !hasHardwareNotch && notchHeight >= Self.handleSize.height + Self.handleTopInset
    }

    /// The open island: `width` wide, `notchHeight + contentHeight` tall, top edge flush with the
    /// screen top, centred on the notch.
    public func islandRect(width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let height = notchHeight + contentHeight
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// A point of slack above the screen's top edge. `CGRect.contains` is half-open at `maxY`, and
    /// the pointer can report `screenFrame.maxY` exactly when it is shoved against the top of the
    /// screen — which is precisely the gesture that must open the island.
    public static let hoverTopSlack: CGFloat = 1

    /// The rect the pointer must be in to count as hovering. It grows left, right and down by the
    /// margin; the top stays pinned to the screen's top edge (plus `hoverTopSlack`), because there
    /// is nothing above it to reach from.
    public static func hoverRect(around rect: CGRect, margin: CGFloat, screenFrame: CGRect) -> CGRect {
        let minY = rect.minY - margin
        return CGRect(
            x: rect.minX - margin,
            y: minY,
            width: rect.width + margin * 2,
            height: screenFrame.maxY + hoverTopSlack - minY
        )
    }

    /// A hardware notch needs every signal to agree: a top safe area, both auxiliary areas, and
    /// the right-hand one actually lying to the right of the left-hand one — otherwise the width
    /// between them is not a notch. Anything else — an external display, a display whose menu bar
    /// is hidden — gets the virtual notch, whose height is the menu-bar band and may be 0.
    public static func forScreen(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        leftAuxiliary: CGRect?,
        rightAuxiliary: CGRect?
    ) -> NotchGeometry {
        if safeAreaTop > 0, let left = leftAuxiliary, let right = rightAuxiliary, right.minX > left.maxX {
            return NotchGeometry(
                screenFrame: frame,
                hasHardwareNotch: true,
                notchWidth: frame.width - left.width - right.width,
                notchHeight: safeAreaTop
            )
        }
        return NotchGeometry(
            screenFrame: frame,
            hasHardwareNotch: false,
            notchWidth: virtualNotchWidth,
            notchHeight: max(0, frame.maxY - visibleFrame.maxY)
        )
    }
}
