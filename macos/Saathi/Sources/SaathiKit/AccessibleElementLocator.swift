//
//  AccessibleElementLocator.swift
//  SaathiKit
//
//  The control a look's answer is about, found by what macOS Accessibility knows rather than by
//  what the pixels show. "Edit" on every row of a list is forty identical captions to a picture,
//  and the eye's own error decides between them. Accessibility knows the control's role and the
//  title of the row it sits in, so "the Edit button on the openclicky row" can be answered from
//  the request itself. OpenClicky's `AccessibleElementLocator`, in Saathi's coordinates.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One control from the front window's Accessibility tree, in screen points.
public struct AccessibleElement: Equatable, Sendable {
    /// AX role: `AXButton`, `AXLink`, `AXStaticText`.
    public let role: String
    /// The control's own caption: its title, or its description or value when it has no title.
    public let title: String
    /// Titles of the groups it sits in, nearest first. This is where a list row's name lives.
    public let containerTitles: [String]
    public let center: CGPoint

    public init(role: String, title: String, containerTitles: [String] = [], center: CGPoint) {
        self.role = role
        self.title = title
        self.containerTitles = containerTitles
        self.center = center
    }
}

public enum AccessibleElementLocator {

    private struct Scored {
        let element: AccessibleElement
        let score: Int
        let distance: CGFloat
    }

    /// The control captioned `hint` that the request is actually about, among those within
    /// `maxDistance` of the eye's point. Ranked by what the request says rather than by distance
    /// alone: a word of the request appearing in a candidate's container titles is strong
    /// evidence, and a control beats a static label repeating its caption. Distance only breaks
    /// ties, and two candidates that tie and sit closer together than `ambiguityMargin` cannot be
    /// told apart here either — nil, and the eye's point stands.
    public static func bestMatch(
        hint: String, userRequest: String?, near guess: CGPoint,
        in candidates: [AccessibleElement], maxDistance: CGFloat, ambiguityMargin: CGFloat
    ) -> AccessibleElement? {
        let needle = normalize(hint)
        guard needle.count >= 3, !ScreenTextLocator.genericWords.contains(needle) else { return nil }

        // Words of the request that could name a row or section: long enough to be distinctive,
        // not a generic UI noun, and not the caption itself, which every candidate carries.
        let distinguishing = Set(words(in: userRequest ?? ""))
            .filter { $0.count >= 3 && !ScreenTextLocator.genericWords.contains($0) && $0 != needle }

        var scored: [Scored] = []
        for candidate in candidates where carriesCaption(candidate, needle: needle) {
            let distance = hypot(candidate.center.x - guess.x, candidate.center.y - guess.y)
            guard distance <= maxDistance else { continue }
            let containerWords = Set(candidate.containerTitles.flatMap { words(in: $0) })
            let named = distinguishing.filter { containerWords.contains($0) }.count
            let control = PointerGrounding.actionableRoles.contains(candidate.role) ? 2 : 0
            scored.append(Scored(element: candidate, score: named * 3 + control, distance: distance))
        }
        scored.sort { $0.score == $1.score ? $0.distance < $1.distance : $0.score > $1.score }

        guard let best = scored.first else { return nil }
        if let runnerUp = scored.dropFirst().first, runnerUp.score == best.score,
           runnerUp.distance - best.distance < ambiguityMargin {
            return nil
        }
        return best.element
    }

    /// Whether the control's own caption is the one asked for: the whole caption, or as one of its
    /// words ("Edit profile" answers to "edit").
    private static func carriesCaption(_ candidate: AccessibleElement, needle: String) -> Bool {
        let title = normalize(candidate.title)
        return title == needle || words(in: title).contains(needle)
    }

    private static func normalize(_ text: String) -> String { words(in: text).joined(separator: " ") }

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    // MARK: the front window

    /// Every captioned control in the front app's focused window, in screen points. Empty without
    /// the Accessibility grant or over an app that exposes no tree. Only the front window: a
    /// control behind it is not a candidate, which is the same limit the picture has.
    public static func controlsInFrontWindow() -> [AccessibleElement] {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return [] }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window = PointerGrounding.copyElement(application, kAXFocusedWindowAttribute)
                ?? PointerGrounding.copyElement(application, kAXMainWindowAttribute) else { return [] }

        var controls: [AccessibleElement] = []
        var queue: [(element: AXUIElement, depth: Int, containers: [String])] = [(window, 0, [])]
        var visited = 0
        // A deep tree costs more than the pass is worth.
        while !queue.isEmpty, visited < 600 {
            let (element, depth, containers) = queue.removeFirst()
            visited += 1
            let role = PointerGrounding.copyString(element, kAXRoleAttribute) ?? ""
            let caption = PointerGrounding.copyString(element, kAXTitleAttribute)
                ?? PointerGrounding.copyString(element, kAXDescriptionAttribute)
                ?? PointerGrounding.copyString(element, kAXValueAttribute)
                ?? ""
            if !caption.isEmpty, !PointerGrounding.secureRoles.contains(role), let frame = PointerGrounding.copyFrame(element) {
                controls.append(AccessibleElement(
                    role: role, title: String(caption.prefix(PointerGrounding.maxCaptionLength)),
                    containerTitles: containers, center: CGPoint(x: frame.midX, y: frame.midY)))
            }
            guard depth < 12 else { continue }
            // A captioned group is the row or section its children sit in; the three nearest are
            // enough to tell two identical buttons apart.
            let childContainers = caption.isEmpty || PointerGrounding.actionableRoles.contains(role)
                ? containers
                : Array(([caption] + containers).prefix(PointerGrounding.maxContainers))
            for child in PointerGrounding.copyChildren(element) {
                queue.append((child, depth + 1, childContainers))
            }
        }
        return controls
    }
}
