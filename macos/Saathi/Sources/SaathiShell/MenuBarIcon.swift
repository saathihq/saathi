//
//  MenuBarIcon.swift
//  SaathiShell
//
//  The menu-bar image: the pointer body from the mascot data, drawn as a template so macOS tints
//  it for light and dark menu bars. No eyes — at 18 pt they are under a pixel, which is also why
//  the app icon's 16 pt variant drops them.
//

import AppKit
import SaathiMascot

public enum MenuBarIcon {
    public static func image(data: MascotData, side: CGFloat = 18) -> NSImage {
        let outline = (try? data.bodyOutline()) ?? CGMutablePath()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = outline.boundingBoxOfPath
            // Fit the body's bounding box into the square with a 1 pt margin, centred.
            let scale = (side - 2) / max(bounds.width, bounds.height)
            context.translateBy(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.addPath(outline)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
