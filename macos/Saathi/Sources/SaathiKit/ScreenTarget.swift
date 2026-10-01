//
//  ScreenTarget.swift
//  SaathiKit
//
//  Where a look's answer is about, on the screen — and how the spot is found once the eye has
//  said roughly where it is.
//
//  The eye is reliable about *which* thing an answer is about and loose about its pixels:
//  OpenClicky measured Claude putting a paper's "arXiv" link 130 px too high, on the abstract. The
//  text it names has an exact box on the very frame it looked at, so the frame is read for text
//  (Vision, upscaled, because UI captions are small) and the eye's point is snapped to the nearest
//  copy of that text. Icons have no text and keep the eye's point. The matching here is
//  OpenClicky's `ScreenTextLocator`, in Saathi's coordinates.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A spot on the screen, in the global top-left-origin points that `CGEvent` and
/// `CGDisplayBounds` use — the same frame of reference the captured display is described in.
public struct ScreenTarget: Equatable, Sendable {
    public let point: CGPoint
    /// What the element shows, when it shows any text: "arXiv" for a link that reads arXiv.
    public let visibleText: String?
    /// How the spot was settled on, for the log: by text, by Accessibility, or by the eye alone.
    public let how: String

    public init(point: CGPoint, visibleText: String? = nil, how: String) {
        self.point = point
        self.visibleText = visibleText
        self.how = how
    }
}

/// What a look came back with: the answer to be spoken, and where it points, if anywhere.
public struct ScreenLook: Equatable, Sendable {
    public let answer: String
    public let target: ScreenTarget?

    public init(answer: String, target: ScreenTarget? = nil) {
        self.answer = answer
        self.target = target
    }
}

/// One line of text found on the frame, in screen points.
public struct ScreenTextLine: Equatable, Sendable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }

    /// The box of a range within the line, placed along it in proportion. Close enough for a word
    /// in a short caption, which is what a hint nearly always is.
    func box(for range: Range<String.Index>) -> CGRect {
        let count = CGFloat(max(text.count, 1))
        let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / count
        let end = CGFloat(text.distance(from: text.startIndex, to: range.upperBound)) / count
        return CGRect(x: box.minX + box.width * start, y: box.minY, width: box.width * (end - start), height: box.height)
    }
}

public struct ScreenTextMatch: Equatable, Sendable {
    /// The line the match was found in, as read — so "HNew" or "Now" are possible.
    public let text: String
    public let center: CGPoint
    /// How far from the eye's point, in points.
    public let distance: CGFloat
}

public enum ScreenTextLocator {

    /// Words that describe a control rather than name it; never matched on their own.
    static let genericWords: Set<String> = [
        "button", "btn", "menu", "icon", "link", "tab", "field", "box", "option", "item", "toggle", "checkbox",
        "dropdown", "bar", "panel", "window", "dialog", "input", "label", "text", "list", "row", "section", "control",
        "the", "and", "for", "with", "top", "left", "right", "bottom", "here", "this", "that",
    ]

    /// The copy of `hint` on the frame nearest to `guess`: the whole hint first, then its
    /// distinctive words. Exact (case-insensitive) matches only — the hint is the eye's idea of
    /// the caption, and a near miss is as likely a different element as a misread. Nil when the
    /// hint is empty or generic, nothing is within `maxDistance`, or two copies are closer
    /// together than `ambiguityMargin`: then distance is noise, not evidence, and nothing is
    /// snapped to rather than the wrong one.
    public static func locate(
        _ hint: String, near guess: CGPoint, in lines: [ScreenTextLine], maxDistance: CGFloat, ambiguityMargin: CGFloat
    ) -> ScreenTextMatch? {
        let needle = normalize(hint)
        guard needle.count >= 3, !genericWords.contains(needle) else { return nil }

        if let match = nearest(exactMatches(of: needle, in: lines), to: guess, within: maxDistance, ambiguityMargin: ambiguityMargin) {
            return match
        }
        let words = needle.split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !genericWords.contains($0) }
            .sorted { $0.count > $1.count }
        for word in words where word != needle {
            if let match = nearest(exactMatches(of: word, in: lines), to: guess, within: maxDistance, ambiguityMargin: ambiguityMargin) {
                return match
            }
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func exactMatches(of needle: String, in lines: [ScreenTextLine]) -> [ScreenTextMatch] {
        var matches: [ScreenTextMatch] = []
        for line in lines {
            var searchRange = line.text.startIndex..<line.text.endIndex
            while let found = line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                let box = line.box(for: found)
                matches.append(ScreenTextMatch(text: line.text, center: CGPoint(x: box.midX, y: box.midY), distance: 0))
                guard found.upperBound < line.text.endIndex else { break }
                searchRange = found.upperBound..<line.text.endIndex
            }
        }
        return matches
    }

    private static func nearest(
        _ matches: [ScreenTextMatch], to guess: CGPoint, within maxDistance: CGFloat, ambiguityMargin: CGFloat
    ) -> ScreenTextMatch? {
        let inRange = matches
            .map { ScreenTextMatch(text: $0.text, center: $0.center, distance: hypot($0.center.x - guess.x, $0.center.y - guess.y)) }
            .filter { $0.distance <= maxDistance }
            .sorted { $0.distance < $1.distance }
        guard let nearest = inRange.first else { return nil }
        if let runnerUp = inRange.dropFirst().first, runnerUp.distance - nearest.distance < ambiguityMargin { return nil }
        return nearest
    }
}

/// Vision's text recognition over the captured frame, off the main thread. About 400 ms for a
/// display's frame upscaled 2×; it is started alongside the eye's request, so it costs no wait.
public enum ScreenTextRecognizer {

    public static func recognize(png: Data, geometry: ScreenCapture.Geometry, upscale: CGFloat = 2) async throws -> [ScreenTextLine] {
        try await Task.detached(priority: .userInitiated) {
            try recognizeNow(png: png, geometry: geometry, upscale: upscale)
        }.value
    }

    private static func recognizeNow(png: Data, geometry: ScreenCapture.Geometry, upscale: CGFloat) throws -> [ScreenTextLine] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenSightError.captureFailed("the frame could not be read for text")
        }
        let width = CGFloat(decoded.width), height = CGFloat(decoded.height)
        var image = decoded
        // UI captions are about 11 px tall on a 1×, and the recogniser is written for prose.
        if upscale != 1,
           let context = CGContext(
            data: nil, width: Int(width * upscale), height: Int(height * upscale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width * upscale, height: height * upscale))
            if let scaled = context.makeImage() { image = scaled }
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Captions are not prose: correction turns "Repos" into "Ropes".
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        // Vision's boxes are normalised with a bottom-left origin. Into the frame's pixels, top-left
        // origin, and from there into screen points.
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let normalized = observation.boundingBox
            let pixels = CGRect(
                x: normalized.minX * width, y: (1 - normalized.maxY) * height,
                width: normalized.width * width, height: normalized.height * height)
            return ScreenTextLine(text: candidate.string, box: geometry.rect(ofPixels: pixels))
        }
    }
}
