//
//  PointerGrounding.swift
//  SaathiKit
//
//  What macOS Accessibility knows about the thing under the pointer, in words a vision model can
//  use.
//
//  A screenshot says what the screen looks like; it does not say which of forty identical rows the
//  pointer is on. OpenClicky's `AccessibleElementLocator` put the reason plainly: pixels make
//  identical captions indistinguishable, and the model's own error decides between them.
//  Accessibility knows more than the pixels do — each control carries a role and a caption, and it
//  sits inside a row or group that has its own title.
//
//  ── What is carried over, and what is not ────────────────────────────────────
//  OpenClicky walks a whole window because it has to find the control a model *guessed at*. Saathi
//  asks the opposite question — the pointer is already on the thing — so this hit-tests one point
//  and walks up the parents instead. The caption order (title, description, value), the rule for
//  which ancestors count as containers, the three-container cap and the actionable-role set are
//  OpenClicky's, unchanged.
//
//  Nothing here is required for sight to work. Without the Accessibility grant, or over an app
//  that exposes no tree, `context(at:)` is nil and `ScreenSight` sends its two pictures as before.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The thing under the pointer, as Accessibility describes it.
public struct PointerContext: Equatable, Sendable {
    /// The app that owns the element, e.g. "Spotify".
    public let appName: String?
    /// Title of the window the element is in.
    public let windowTitle: String?
    /// AX role, e.g. `AXButton`, `AXStaticText`, `AXRow`.
    public let role: String
    /// The element's own caption; empty for a row or cell that only groups other things.
    public let caption: String
    /// Captions of the groups the element sits in, nearest ancestor first. This is where a list
    /// row's name lives.
    public let containerTitles: [String]
    /// When the element has no caption of its own, the captions of what is inside it: a song row's
    /// title and artist.
    public let nearbyCaptions: [String]

    public init(
        appName: String?, windowTitle: String?, role: String, caption: String,
        containerTitles: [String] = [], nearbyCaptions: [String] = []
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.role = role
        self.caption = caption
        self.containerTitles = containerTitles
        self.nearbyCaptions = nearbyCaptions
    }

    /// Whether there is anything here worth telling a model. An uncaptioned element in an untitled
    /// window of an unnamed app is not evidence of anything.
    public var isInformative: Bool {
        !caption.isEmpty || !nearbyCaptions.isEmpty || !containerTitles.isEmpty
    }

    /// One sentence for the vision model: what the pointer is over, what that sits in, and where.
    public var sentence: String {
        var parts: [String] = []
        let noun = PointerGrounding.word(forRole: role)
        if !caption.isEmpty {
            parts.append("the pointer is over \(noun) captioned \"\(caption)\"")
        } else if !nearbyCaptions.isEmpty {
            let inside = nearbyCaptions.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("the pointer is over \(noun) containing \(inside)")
        } else {
            parts.append("the pointer is over \(noun) with no caption")
        }
        if !containerTitles.isEmpty {
            let groups = containerTitles.map { "\"\($0)\"" }.joined(separator: ", inside ")
            parts.append("inside \(groups)")
        }
        switch (appName, windowTitle) {
        case let (app?, window?): parts.append("in the \(app) window \"\(window)\"")
        case let (app?, nil): parts.append("in \(app)")
        case let (nil, window?): parts.append("in the window \"\(window)\"")
        case (nil, nil): break
        }
        return "macOS Accessibility reports that " + parts.joined(separator: ", ") + "."
    }
}

public enum PointerGrounding {

    /// Roles a user can actually point at and click. OpenClicky's set: a captioned ancestor with
    /// one of these roles is a control, not a container.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXTextField", "AXTextArea", "AXDisclosureTriangle", "AXTab",
    ]

    /// Never read: what is typed into one of these is not Saathi's to repeat, and macOS withholds
    /// the value anyway.
    static let secureRoles: Set<String> = ["AXSecureTextField"]

    static let maxCaptionLength = 120
    static let maxContainers = 3
    static let maxNearbyCaptions = 6

    /// The role as a person would say it. Unknown roles become "an element" rather than leaking
    /// "AXSplitGroup" into a sentence a model may read aloud.
    static func word(forRole role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXPopUpButton": return "a button"
        case "AXLink": return "a link"
        case "AXMenuItem", "AXMenuBarItem": return "a menu item"
        case "AXCheckBox": return "a checkbox"
        case "AXRadioButton": return "a radio button"
        case "AXTextField", "AXTextArea", "AXSecureTextField": return "a text field"
        case "AXStaticText": return "text"
        case "AXImage": return "an image"
        case "AXRow": return "a list row"
        case "AXCell": return "a cell"
        case "AXTab", "AXTabGroup": return "a tab"
        case "AXDisclosureTriangle": return "a disclosure triangle"
        case "AXDockItem": return "a Dock item"
        case "AXGroup", "AXList", "AXOutline", "AXTable", "AXScrollArea": return "a group"
        default: return "an element"
        }
    }

    /// Whitespace collapsed and clipped: an `AXValue` can be a whole document.
    static func clipped(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > maxCaptionLength else { return collapsed }
        return String(collapsed.prefix(maxCaptionLength)) + "…"
    }

    /// One step of the walk up from the element under the pointer.
    struct Ancestor: Equatable {
        let role: String
        let caption: String
    }

    /// The container titles among `ancestors` (nearest first): captioned, not themselves controls,
    /// not the window (that is reported separately), not a repeat of the element's own caption, and
    /// three at most — the three nearest are enough to tell two identical buttons apart.
    static func containerTitles(from ancestors: [Ancestor], elementCaption: String) -> [String] {
        var titles: [String] = []
        for ancestor in ancestors {
            guard !ancestor.caption.isEmpty,
                  !actionableRoles.contains(ancestor.role),
                  ancestor.role != "AXWindow", ancestor.role != "AXApplication",
                  ancestor.caption != elementCaption,
                  !titles.contains(ancestor.caption) else { continue }
            titles.append(ancestor.caption)
            if titles.count == maxContainers { break }
        }
        return titles
    }

    // MARK: - Accessibility access

    /// Whether the read below can work at all.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// What is under `point`, in the global top-left-origin coordinates `CGEvent.location` reports
    /// — the same space Accessibility hit-tests in. Nil without the grant, over an app with no
    /// usable tree, or when nothing found has anything to say.
    public static func context(at point: CGPoint) -> PointerContext? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let role = copyString(element, kAXRoleAttribute) ?? ""
        let caption = secureRoles.contains(role) ? "" : clipped(ownCaption(of: element) ?? "")

        var ancestors: [Ancestor] = []
        var windowTitle: String?
        var current = element
        for _ in 0..<12 {
            guard let parent = copyElement(current, kAXParentAttribute) else { break }
            let parentRole = copyString(parent, kAXRoleAttribute) ?? ""
            if parentRole == "AXWindow" {
                windowTitle = copyString(parent, kAXTitleAttribute).map(clipped)
            }
            ancestors.append(Ancestor(role: parentRole, caption: clipped(ownCaption(of: parent) ?? "")))
            if parentRole == "AXApplication" { break }
            current = parent
        }

        var pid: pid_t = 0
        let appName = AXUIElementGetPid(element, &pid) == .success
            ? NSRunningApplication(processIdentifier: pid)?.localizedName
            : nil

        let context = PointerContext(
            appName: appName,
            windowTitle: windowTitle,
            role: role,
            caption: caption,
            containerTitles: containerTitles(from: ancestors, elementCaption: caption),
            nearbyCaptions: caption.isEmpty && !secureRoles.contains(role) ? descendantCaptions(of: element) : []
        )
        return context.isInformative ? context : nil
    }

    /// Title, else description, else value — OpenClicky's order. A value is only used when it is
    /// text: a slider's 0.4 is not a caption.
    private static func ownCaption(of element: AXUIElement) -> String? {
        copyString(element, kAXTitleAttribute)
            ?? copyString(element, kAXDescriptionAttribute)
            ?? copyString(element, kAXValueAttribute)
    }

    /// The captions inside an uncaptioned element, breadth-first and capped hard: this runs while
    /// someone is waiting for an answer.
    private static func descendantCaptions(of element: AXUIElement) -> [String] {
        var captions: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = copyChildren(element).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 40, captions.count < maxNearbyCaptions {
            let (next, depth) = queue.removeFirst()
            visited += 1
            let role = copyString(next, kAXRoleAttribute) ?? ""
            guard !secureRoles.contains(role) else { continue }
            if let caption = ownCaption(of: next).map(clipped), !caption.isEmpty, !captions.contains(caption) {
                captions.append(caption)
            }
            if depth < 4 { queue.append(contentsOf: copyChildren(next).map { ($0, depth + 1) }) }
        }
        return captions
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let string = copyValue(element, attribute) as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        (copyValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
