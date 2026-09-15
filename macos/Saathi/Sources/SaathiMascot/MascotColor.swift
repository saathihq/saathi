//
//  MascotColor.swift
//  SaathiMascot
//
//  One body colour and the two gradient ends the web renderer derives from it.
//

import CoreGraphics
import Foundation

public struct MascotColor: Equatable, Sendable {
    /// "#RRGGBB", as in the palette.
    public var hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public init?(paletteName: String, in data: MascotData) {
        guard let hex = data.palette[paletteName] else { return nil }
        self.hex = hex
    }

    /// Top-right of the body.
    public var light: String { Self.mix(hex, "#ffffff", 0.55) }
    /// Bottom-left of the body.
    public var dark: String { Self.mix(hex, "#000000", 0.42) }

    public var cgColor: CGColor { Self.cgColor(hex: hex) }

    public static func cgColor(hex: String) -> CGColor {
        let (r, g, b) = channels(hex)
        return CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Linear per-channel blend with the web renderer's rounding, returned lower-case.
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        func blend(_ x: Int, _ y: Int) -> Int { Int((Double(x) + Double(y - x) * amount).rounded()) }
        return String(format: "#%02x%02x%02x", blend(ar, br), blend(ag, bg), blend(ab, bb))
    }

    private static func channels(_ hex: String) -> (Int, Int, Int) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = Int(digits, radix: 16) ?? 0
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }
}
