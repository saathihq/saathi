//
//  MascotData.swift
//  SaathiMascot
//
//  The character as data: one body outline, 25 faces, and the tables that say which faces an
//  expression uses and how the body moves while it holds one. Ported from the web renderer's
//  bundle by scripts/port-mascot.py; nothing here is hand-typed.
//

import Foundation

public struct MascotData: Decodable, Sendable {

    public struct Box: Decodable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// Scale first, then translate: p' = p * scale + (tx, ty).
    public struct Transform: Decodable, Sendable {
        public var scale: Double
        public var tx: Double
        public var ty: Double

        public var affine: CGAffineTransform {
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        }
    }

    /// How the body moves while an expression is held. Pairs are [amplitude, period in ms].
    public struct MotionPreset: Decodable, Sendable {
        public var pulse: [Double]?
        public var bob: [Double]?
        public var sway: [Double]?
        public var circle: [Double]?
        public var jitter: [Double]?
        /// [starting scale, duration in ms] — grows in from the starting scale.
        public var enter: [Double]?
        /// Degrees.
        public var tilt: Double?
        /// How much a bob flattens the body at the bottom of its travel.
        public var squash: Double?
        /// Final scale, eased to over 1.4 s.
        public var settle: Double?
    }

    public var bodyPath: String
    public var viewBox: Box
    public var bodyTransform: Transform
    public var faceTransform: Transform
    /// The x the face wraps around when it turns: the centre of the drawing.
    public var eyeRefX: Double
    /// face → eye (left, right) → point → [x, y]
    public var faces: [[[[Double]]]]
    /// face → [half-width, curve, drop below the eyes, tilt in degrees]
    public var mouths: [[Double]]
    /// face → [dx, dy] the whole face drifts by when "look around" is on
    public var gaze: [[Double]]
    /// expression name → face indices, first one shown on entry
    public var expressions: [String: [Int]]
    public var motion: [String: MotionPreset]
    /// expression → [min, max] ms between face changes; null means the face never changes
    public var faceInterval: [String: [Double]?]
    /// expression → [min, max] ms between blinks; null means no auto-blink
    public var blinkInterval: [String: [Double]?]
    public var palette: [String: String]

    public enum LoadError: Error {
        case missingResource
    }

    public static func load() throws -> MascotData {
        guard let url = Bundle.module.url(forResource: "mascot", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try JSONDecoder().decode(MascotData.self, from: Data(contentsOf: url))
    }
}
