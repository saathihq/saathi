//
//  EditMenu.swift
//  SaathiShell
//
//  The one menu an accessory app still needs.
//
//  Saathi is `LSUIElement` / `.accessory`: no Dock tile and no menu bar of its own, so nothing ever
//  built an `NSApp.mainMenu`. Command-key equivalents are dispatched through the main menu, which
//  meant ⌘V had no target anywhere in the app — pasting an API key into the Setup tab silently did
//  nothing and the only way in was the field's own right-click menu. A key is exactly the kind of
//  thing nobody types by hand, so that made the panel feel broken at the one moment it matters.
//
//  The menu is never shown. An accessory app has no menu bar to show it in; it exists purely so
//  `NSApplication` has somewhere to send ⌘X/⌘C/⌘V/⌘A and the responder chain can act on them. The
//  selectors are the standard ones, so whatever text field is first responder handles them itself.
//

import AppKit

public enum EditMenu {

    /// Installs a minimal main menu carrying the standard editing commands.
    ///
    /// Only the items a text field needs. No File, no Window, no About: an accessory app shows none
    /// of it, and every extra item is one more thing that can take a key equivalent away from
    /// something that wanted it.
    public static func install(into application: NSApplication = .shared) {
        let main = NSMenu()

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")

        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            edit.addItem(item)
        }

        editItem.submenu = edit
        main.addItem(editItem)
        application.mainMenu = main
    }

    /// Exposed so a test can assert the set without building an `NSApplication`.
    public static let items: [(title: String, action: Selector, key: String)] = [
        ("Cut", #selector(NSText.cut(_:)), "x"),
        ("Copy", #selector(NSText.copy(_:)), "c"),
        ("Paste", #selector(NSText.paste(_:)), "v"),
        ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ]
}
