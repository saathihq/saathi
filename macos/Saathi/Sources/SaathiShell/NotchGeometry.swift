//
//  NotchGeometry.swift
//  SaathiShell
//
//  Where the notch panel sits. On a notched screen the panel covers the notch (which is black
//  hardware, so anything drawn there is invisible) plus a lip below it where the mascot and the
//  state word live. Without a notch it is a pill under the menu bar. Pure.
//

import CoreGraphics

public enum NotchGeometry {
    /// Height of the visible strip under the notch.
    public static let lip: CGFloat = 28
    public static let pillWidth: CGFloat = 180
    public static let pillHeight: CGFloat = 30
    public static let menuBarHeight: CGFloat = 24

    public static func collapsedFrame(screen: CGRect, safeAreaTop: CGFloat, leftAuxiliary: CGRect?, rightAuxiliary: CGRect?) -> CGRect {
        if safeAreaTop > 0, let left = leftAuxiliary, let right = rightAuxiliary, right.minX > left.maxX {
            let height = safeAreaTop + lip
            return CGRect(x: left.maxX, y: screen.maxY - height, width: right.minX - left.maxX, height: height)
        }
        return CGRect(
            x: screen.midX - pillWidth / 2,
            y: screen.maxY - menuBarHeight - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
    }

    /// Grows down from the collapsed frame's top edge, centred, at least `minWidth` wide.
    public static func expandedFrame(collapsed: CGRect, height: CGFloat, minWidth: CGFloat) -> CGRect {
        let width = max(collapsed.width, minWidth)
        return CGRect(x: collapsed.midX - width / 2, y: collapsed.maxY - height, width: width, height: height)
    }
}
