#!/usr/bin/env swift
//
//  ax-probe.swift — what does an app's Accessibility tree actually expose?
//
//  Pointer grounding (Sources/SaathiKit/PointerGrounding.swift) is only as good as the tree the
//  app under the pointer publishes. Electron and CEF apps publish almost nothing until something
//  asks them to, and whether Saathi should ask is a thing to measure, not to assume.
//
//    swift scripts/ax-probe.swift                          Spotify, as it is
//    swift scripts/ax-probe.swift com.google.Chrome        another app, by bundle id
//    swift scripts/ax-probe.swift com.spotify.client on    set AXManualAccessibility, then measure
//    swift scripts/ax-probe.swift com.spotify.client off   put it back
//
//  Read-only unless `on`/`off` is given. `on` changes the *other* app until it quits: Chromium
//  builds its full accessibility tree, which costs it CPU. Always finish with `off`.
//
//  The terminal running this needs the Accessibility grant, and the screen must be UNLOCKED: with
//  the screen locked every app's windows read as a three-node stub, which is what this measured on
//  the night of 2026-09-22 and why there is no answer recorded yet.
//

import AppKit
import ApplicationServices

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
}
func string(_ element: AXUIElement, _ attribute: String) -> String? {
    (value(element, attribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

guard AXIsProcessTrusted() else {
    print("This terminal has no Accessibility grant (System Settings → Privacy & Security → Accessibility).")
    exit(1)
}
let bundle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.spotify.client"
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
    print("\(bundle) is not running"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 0.5)

if CommandLine.arguments.count > 2 {
    let on = CommandLine.arguments[2] == "on"
    let result = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    print("AXManualAccessibility = \(on):", result == .success ? "ok" : "refused (\(result.rawValue))")
    Thread.sleep(forTimeInterval: 1.5)   // Chromium builds the tree asynchronously
}

let windows = (value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
var queue: [(AXUIElement, Int)] = windows.map { ($0, 1) }
var visited = 0, captioned = 0, deepest = 0
var roles: [String: Int] = [:]
var samples: [String] = []
let menus: Set<String> = ["AXApplication", "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem"]
let started = Date()

while !queue.isEmpty, visited < 4000, Date().timeIntervalSince(started) < 20 {
    let (element, depth) = queue.removeFirst()
    let role = string(element, kAXRoleAttribute) ?? "?"
    if depth > 1, menus.contains(role) { continue }
    visited += 1
    deepest = max(deepest, depth)
    roles[role, default: 0] += 1
    let caption = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? string(element, kAXValueAttribute)
    if let caption {
        captioned += 1
        if samples.count < 14, ["AXRow", "AXCell", "AXStaticText", "AXLink", "AXButton"].contains(role) {
            samples.append("\(role): \(caption.prefix(48))")
        }
    }
    if depth < 25 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
}

print("\(app.localizedName ?? bundle): \(windows.count) window(s), \(visited) elements, \(captioned) captioned, depth \(deepest), "
      + String(format: "%.1fs", Date().timeIntervalSince(started)))
print(roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
samples.forEach { print("   \($0)") }
if visited <= 5 { print("→ A stub. Locked screen, a minimised window, or an app that publishes nothing until asked.") }
